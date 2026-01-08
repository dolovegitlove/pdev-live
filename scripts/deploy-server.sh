#!/usr/bin/env bash
# Git-first deployment for PDev Live server.js
# Prevents: scp bypassing git → fixes get reverted
#
# Usage:
#   ./deploy-server.sh           # Normal deploy (git checks enforced)
#   ./deploy-server.sh --force   # Emergency deploy (logs bypass)

set -euo pipefail

# Configuration
PROJECT_DIR="$HOME/projects/pdev-live"
SERVER_FILE="server/server.js"
REMOTE_HOST="acme"
REMOTE_PATH="/home/acme/pdev-live/server/server.js"
REMOTE_TEMP="/home/acme/pdev-live/server/server.js.deploying"
PM2_SERVICE="pdev-live"
EXPECTED_BRANCH="main"
LOG_FILE="$PROJECT_DIR/.deploy-log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

error() { echo -e "${RED}ERROR:${NC} $1" >&2; }
success() { echo -e "${GREEN}$1${NC}"; }
warn() { echo -e "${YELLOW}WARNING:${NC} $1"; }

# Parse arguments
FORCE_MODE=false
if [[ "${1:-}" == "--force" ]]; then
    FORCE_MODE=true
    warn "FORCE MODE ENABLED - Git checks bypassed"
    echo "$(date -Iseconds) FORCE_DEPLOY user=$(whoami) pwd=$(pwd)" >> "$LOG_FILE"
fi

cd "$PROJECT_DIR"

# 0. Verify we're in a git repo
if ! git rev-parse --git-dir > /dev/null 2>&1; then
    error "Not a git repository: $PROJECT_DIR"
    exit 1
fi

# 1. Check current branch (skip in force mode)
if [[ "$FORCE_MODE" == false ]]; then
    CURRENT_BRANCH=$(git branch --show-current)
    if [[ "$CURRENT_BRANCH" != "$EXPECTED_BRANCH" ]]; then
        error "Must be on '$EXPECTED_BRANCH' branch (currently on '$CURRENT_BRANCH')"
        echo ""
        echo "Switch branches:"
        echo "  git checkout $EXPECTED_BRANCH"
        exit 1
    fi
fi

# 2. Check for uncommitted changes (skip in force mode)
if [[ "$FORCE_MODE" == false ]]; then
    if ! git diff --quiet "$SERVER_FILE"; then
        error "Uncommitted changes in $SERVER_FILE"
        echo ""
        echo "You must commit changes before deploying:"
        echo "  git add $SERVER_FILE"
        echo "  git commit -m 'Your commit message'"
        echo "  git push origin $EXPECTED_BRANCH"
        echo ""
        echo "Then run this script again."
        echo ""
        echo "Emergency deploy (bypasses git checks, logged):"
        echo "  ./deploy-server.sh --force"
        exit 1
    fi

    # Also check staged but uncommitted
    if ! git diff --cached --quiet "$SERVER_FILE"; then
        error "Staged but uncommitted changes in $SERVER_FILE"
        echo "  Run: git commit -m 'Your commit message'"
        exit 1
    fi
fi

# 3. Check if local is ahead of remote (skip in force mode)
if [[ "$FORCE_MODE" == false ]]; then
    git fetch origin "$EXPECTED_BRANCH" --quiet 2>/dev/null || {
        error "Cannot fetch from origin. Check network connection."
        exit 1
    }

    LOCAL=$(git rev-parse HEAD)
    REMOTE=$(git rev-parse "origin/$EXPECTED_BRANCH")

    if [[ "$LOCAL" != "$REMOTE" ]]; then
        # Determine direction
        if git merge-base --is-ancestor "$REMOTE" "$LOCAL"; then
            error "Local commits not pushed to origin"
            echo "  Run: git push origin $EXPECTED_BRANCH"
        else
            error "Local is behind origin (pull required)"
            echo "  Run: git pull origin $EXPECTED_BRANCH"
        fi
        exit 1
    fi
fi

# 4. Syntax check ALWAYS runs (even with --force)
echo "Checking syntax..."
if ! node -c "$SERVER_FILE" 2>&1; then
    error "Syntax error in $SERVER_FILE"
    echo "Fix syntax errors before deploying."
    exit 1
fi
success "Syntax check passed"

# 5. Confirm force mode
if [[ "$FORCE_MODE" == true ]]; then
    echo ""
    warn "You are about to deploy WITHOUT git verification."
    read -p "Type 'DEPLOY' to confirm: " CONFIRM
    if [[ "$CONFIRM" != "DEPLOY" ]]; then
        echo "Deployment cancelled."
        exit 1
    fi
    echo "$(date -Iseconds) FORCE_DEPLOY_CONFIRMED" >> "$LOG_FILE"
fi

# 6. Deploy with atomic move (prevents partial uploads)
if [[ "$FORCE_MODE" == false ]]; then
    success "Git is clean and pushed"
fi
echo "Deploying $SERVER_FILE to $REMOTE_HOST..."

# Upload to temp file first
if ! scp "$SERVER_FILE" "$REMOTE_HOST:$REMOTE_TEMP"; then
    error "SCP upload failed"
    exit 1
fi

# Atomic move (prevents serving partial file)
if ! ssh "$REMOTE_HOST" "mv '$REMOTE_TEMP' '$REMOTE_PATH'"; then
    error "Failed to move deployed file into place"
    ssh "$REMOTE_HOST" "rm -f '$REMOTE_TEMP'" 2>/dev/null || true
    exit 1
fi

# 7. Restart PM2 with error handling
echo "Restarting $PM2_SERVICE..."
if ! ssh "$REMOTE_HOST" "pm2 restart $PM2_SERVICE"; then
    error "PM2 restart failed"
    echo "Check server logs: ssh $REMOTE_HOST 'pm2 logs $PM2_SERVICE --lines 50'"
    exit 1
fi

# 8. Verify service is running
sleep 2  # Give PM2 time to restart
STATUS=$(ssh "$REMOTE_HOST" "pm2 jlist 2>/dev/null | jq -r '.[] | select(.name==\"$PM2_SERVICE\") | .pm2_env.status'" 2>/dev/null || echo "unknown")

if [[ "$STATUS" == "online" ]]; then
    success "Deployment complete"
    ssh "$REMOTE_HOST" "pm2 show $PM2_SERVICE | grep -E 'status|uptime|restarts'"
else
    # Fallback status check
    FALLBACK_STATUS=$(ssh "$REMOTE_HOST" "pm2 show $PM2_SERVICE 2>/dev/null | grep 'status' | head -1" || echo "")
    if [[ "$FALLBACK_STATUS" == *"online"* ]]; then
        success "Deployment complete"
        ssh "$REMOTE_HOST" "pm2 show $PM2_SERVICE | grep -E 'status|uptime|restarts'"
    else
        warn "Service status unclear. Check manually:"
        echo "  ssh $REMOTE_HOST 'pm2 logs $PM2_SERVICE --lines 50'"
    fi
fi

# 9. Log successful deploy
echo "$(date -Iseconds) DEPLOY_SUCCESS commit=$(git rev-parse --short HEAD 2>/dev/null || echo 'unknown')" >> "$LOG_FILE"
