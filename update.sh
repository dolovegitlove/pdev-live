#!/bin/bash
# PDev Live Update Script - Full Stack Deployment
# Includes: backup, validation, frontend deployment, rollback, verification
set -euo pipefail

# Configuration
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/var/www/walletsnack.com/pdev/live-backups/$TIMESTAMP"
DEPLOY_DIR="/var/www/walletsnack.com/pdev/live"
SERVICE_DIR="/opt/services/pdev-live"
DEPLOY_LOG="$HOME/pdev-live-deployment.log"
PROJECT_DIR="$HOME/projects/pdev-live"

# Logging setup
exec > >(tee -a "$DEPLOY_LOG") 2>&1
echo ""
echo "=========================================="
echo "PDev Live Deployment - $TIMESTAMP"
echo "=========================================="

# PHASE 1: Backup current production files
echo ""
echo "📦 Phase 1: Backing up production files..."
ssh acme "mkdir -p $BACKUP_DIR && cp $DEPLOY_DIR/*.{html,css,js} $BACKUP_DIR/ 2>/dev/null || true"
ssh acme "cp $SERVICE_DIR/server.js $SERVICE_DIR/server.js.bak-$TIMESTAMP 2>/dev/null || true"
ssh acme "cp $SERVICE_DIR/doc-contract.json $SERVICE_DIR/doc-contract.json.bak-$TIMESTAMP 2>/dev/null || true"
echo "✅ Backup saved to: $BACKUP_DIR"

# PHASE 2: Pull latest code
echo ""
echo "📥 Phase 2: Pulling latest code..."
cd "$PROJECT_DIR"
COMMIT_BEFORE=$(git rev-parse HEAD)
git pull origin main
COMMIT_AFTER=$(git rev-parse HEAD)

if [ "$COMMIT_BEFORE" = "$COMMIT_AFTER" ]; then
    echo "ℹ️  No new commits - already up to date"
else
    echo "✅ Updated from $COMMIT_BEFORE to $COMMIT_AFTER"
fi

# PHASE 3: Syntax validation (local)
echo ""
echo "🔍 Phase 3: Validating syntax..."

# Validate server.js
if ! node -c "$PROJECT_DIR/server/server.js" 2>/dev/null; then
    echo "❌ Syntax error in server.js"
    exit 1
fi

# Validate doc-contract.json
if ! python3 -m json.tool "$PROJECT_DIR/server/doc-contract.json" > /dev/null 2>&1; then
    echo "❌ Invalid JSON in doc-contract.json"
    exit 1
fi

# Basic CSS validation - check for proper structure (allow comment-only files)
for file in "$PROJECT_DIR/frontend"/*.css; do
    if [ -f "$file" ]; then
        # Check if file has actual CSS rules (not just comments)
        if grep -qE '^[^/\*].*\{' "$file"; then
            # If it has CSS rules, verify closing braces exist
            if ! grep -q "}" "$file"; then
                echo "❌ CSS syntax error in $(basename "$file") - missing closing braces"
                exit 1
            fi
        fi
    fi
done

# Validate HTML has proper structure
for file in "$PROJECT_DIR/frontend"/*.html; do
    if [ -f "$file" ] && ! grep -q "</html>" "$file"; then
        echo "❌ HTML syntax error in $(basename "$file") - missing </html>"
        exit 1
    fi
done

echo "✅ Syntax validation passed"

# PHASE 4: Deploy backend
echo ""
echo "🔧 Phase 4: Deploying backend..."
scp "$PROJECT_DIR/server/server.js" acme:"$SERVICE_DIR/server.js"
scp "$PROJECT_DIR/server/doc-contract.json" acme:"$SERVICE_DIR/doc-contract.json"
echo "✅ Backend deployed"

# PHASE 5: Deploy frontend (atomic copy with rsync)
echo ""
echo "🎨 Phase 5: Deploying frontend..."

# Use rsync for atomic deployment with verification
rsync -avz --checksum \
  --include='*.html' \
  --include='*.css' \
  --include='*.js' \
  --exclude='*.bak' \
  --exclude='node_modules/' \
  "$PROJECT_DIR/frontend/" acme:"$DEPLOY_DIR/"

# Set correct permissions
ssh acme "chmod 644 $DEPLOY_DIR/*.{html,css,js} 2>/dev/null || true"

# Clean up local .bak files after successful deployment
rm -f "$PROJECT_DIR/frontend"/*.bak

echo "✅ Frontend deployed"

# PHASE 6: Restart backend
echo ""
echo "🔄 Phase 6: Restarting backend..."
ssh acme "pm2 restart pdev-live --update-env"
sleep 5
echo "✅ Backend restarted"

# PHASE 7: Verify deployment
echo ""
echo "🔍 Phase 7: Verifying deployment..."

# Check PM2 process is online
if ! ssh acme 'pm2 describe pdev-live | grep -q "status.*online"'; then
    echo "❌ PM2 process not online - triggering rollback"
    echo "🔄 Rolling back..."
    ssh acme "cp $BACKUP_DIR/* $DEPLOY_DIR/ 2>/dev/null || true"
    ssh acme "cp $SERVICE_DIR/server.js.bak-$TIMESTAMP $SERVICE_DIR/server.js 2>/dev/null || true"
    ssh acme "pm2 restart pdev-live"
    exit 1
fi

# Check new CSS files exist
for css_file in pdev-live.css session-specific.css project-specific.css index-specific.css; do
    if ! ssh acme "test -f $DEPLOY_DIR/$css_file"; then
        echo "❌ Deployment verification failed - $css_file missing"
        echo "🔄 Rolling back..."
        ssh acme "cp $BACKUP_DIR/* $DEPLOY_DIR/ 2>/dev/null || true"
        exit 1
    fi
done

# Check HTTP accessibility (basic)
if ! curl -f -s https://walletsnack.com/pdev/live/pdev-live.css > /dev/null 2>&1; then
    echo "⚠️  Warning: HTTP verification failed - CSS may not be accessible yet"
    echo "   This could be a temporary DNS/cache issue"
fi

echo "✅ Deployment verification passed"

# PHASE 8: Cleanup old backups
echo ""
echo "🧹 Phase 8: Cleaning up old backups..."

# Keep only last 10 backups
ssh acme "cd /var/www/walletsnack.com/pdev/live-backups && ls -t | tail -n +11 | xargs -r rm -rf"

# Delete backups older than 30 days
ssh acme "find /var/www/walletsnack.com/pdev/live-backups -type d -mtime +30 -delete 2>/dev/null || true"

# Delete old service backups (keep last 5)
ssh acme "cd $SERVICE_DIR && ls -t server.js.bak-* 2>/dev/null | tail -n +6 | xargs -r rm -f"

echo "✅ Backup cleanup complete"

# PHASE 9: Record deployment
echo ""
echo "📝 Phase 9: Recording deployment..."
echo "$COMMIT_AFTER" | ssh acme "cat > $SERVICE_DIR/.deployed_version"
echo "✅ Deployment recorded"

# Final summary
echo ""
echo "=========================================="
echo "🎉 Deployment Completed Successfully!"
echo "=========================================="
echo "   Timestamp: $TIMESTAMP"
echo "   Commit: $COMMIT_AFTER"
echo "   Backend: $SERVICE_DIR"
echo "   Frontend: $DEPLOY_DIR"
echo "   Backup: $BACKUP_DIR"
echo "   Log: $DEPLOY_LOG"
echo ""
echo "📋 Post-deployment checklist:"
echo "   [ ] Run: /cache-bust https://walletsnack.com/pdev/live/"
echo "   [ ] Test: https://walletsnack.com/pdev/live/ (Ctrl+Shift+R)"
echo "   [ ] Verify: F12 console has zero CSS 404 errors"
echo "   [ ] Check all pages: index.html, session.html, project.html"
echo ""
