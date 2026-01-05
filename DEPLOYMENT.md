# PDev Live Deployment Guide

Complete deployment documentation for PDev Live production system.

## Quick Start

```bash
cd ~/projects/pdev-live
./update.sh
```

That's it! The update.sh script handles everything automatically.

---

## 9-Phase Deployment Process

### Phase 1: Backup Current Production Files

**What happens:**
```bash
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
BACKUP_DIR="/var/www/vyxenai.com/pdev-backups/$TIMESTAMP"
ssh acme "mkdir -p $BACKUP_DIR && cp $DEPLOY_DIR/*.{html,css,js} $BACKUP_DIR/"
```

**Why:** Safe rollback if deployment fails

**Backup locations:**
- Frontend: `/var/www/vyxenai.com/pdev-backups/YYYYMMDD_HHMMSS/`
- Backend: `/opt/services/pdev-live/server.js.bak-YYYYMMDD_HHMMSS`
- Config: `/opt/services/pdev-live/doc-contract.json.bak-YYYYMMDD_HHMMSS`

**Retention:** Keep 10 most recent, delete >30 days

---

### Phase 2: Pull Latest Code from GitHub

**What happens:**
```bash
cd ~/projects/pdev-live
COMMIT_BEFORE=$(git rev-parse HEAD)
git pull origin main
COMMIT_AFTER=$(git rev-parse HEAD)
```

**Why:** Get latest changes from repository

**Output:**
- If no changes: "ℹ️  No new commits - already up to date"
- If updated: "✅ Updated from <hash> to <hash>"

---

### Phase 3: Syntax Validation

**What happens:**

```bash
# Validate server.js
node -c server/server.js

# Validate doc-contract.json
python3 -m json.tool server/doc-contract.json > /dev/null

# Validate CSS files (allow comment-only files)
for file in frontend/*.css; do
  if grep -qE '^[^/\*].*\{' "$file"; then
    grep -q "}" "$file" || exit 1
  fi
done

# Validate HTML files
for file in frontend/*.html; do
  grep -q "</html>" "$file" || exit 1
done
```

**Why:** Catch syntax errors before deploying

**Checks:**
- ✅ Node.js files (server.js) - `node -c` syntax check
- ✅ JSON files (doc-contract.json) - `json.tool` validation
- ✅ CSS files - Opening/closing brace validation
- ✅ HTML files - Closing `</html>` tag validation

**Failures:**
- ❌ Syntax error in server.js → Deployment aborts
- ❌ Invalid JSON in doc-contract.json → Deployment aborts
- ❌ CSS syntax error → Deployment aborts (unless comment-only file)
- ❌ HTML missing </html> → Deployment aborts

---

### Phase 4: Deploy Backend via SCP

**What happens:**
```bash
scp server/server.js acme:/opt/services/pdev-live/server.js
scp server/doc-contract.json acme:/opt/services/pdev-live/doc-contract.json
```

**Why:** Update backend server code and configuration

**Files deployed:**
- `server.js` (main server)
- `doc-contract.json` (document type definitions)

---

### Phase 5: Deploy Frontend via Rsync (Atomic)

**What happens:**
```bash
rsync -avz --checksum \
  --include='*.html' \
  --include='*.css' \
  --include='*.js' \
  --exclude='*.bak' \
  --exclude='node_modules/' \
  frontend/ acme:/var/www/vyxenai.com/pdev/
```

**Why:** Atomic deployment prevents race conditions

**Rsync benefits:**
- Only transfers changed files (--checksum)
- Atomic file replacement (no partial updates)
- Excludes backup and development files
- Preserves permissions

**Files deployed:**
- index.html, session.html, project.html, live.html
- pdev-live.css (12KB base styles)
- session-specific.css (2.3KB)
- project-specific.css (5.8KB)
- index-specific.css (333B)
- mgmt.js (management functions)

**Permissions:**
```bash
ssh acme "chmod 644 /var/www/vyxenai.com/pdev/*.{html,css,js}"
```

**Cleanup:**
```bash
rm -f frontend/*.bak  # Remove local backup files after successful deployment
```

---

### Phase 6: Restart PM2 Service

**What happens:**
```bash
ssh acme "pm2 restart pdev-live --update-env"
sleep 5  # Wait for service to stabilize
```

**Why:** Load new backend code into production

**PM2 commands:**
- `pm2 restart pdev-live` - Graceful restart with zero downtime
- `--update-env` - Refresh environment variables
- `sleep 5` - Wait for process to stabilize before verification

---

### Phase 7: Deployment Verification

**What happens:**

```bash
# Check PM2 process is online
ssh acme 'pm2 describe pdev-live | grep -q "status.*online"'

# Verify all CSS files exist
for css_file in pdev-live.css session-specific.css project-specific.css index-specific.css; do
  ssh acme "test -f /var/www/vyxenai.com/pdev/$css_file"
done

# Check HTTP accessibility (basic)
curl -f -s https://vyxenai.com/pdev/pdev-live.css > /dev/null
```

**Why:** Ensure deployment succeeded before marking complete

**Checks:**
1. ✅ PM2 process status = "online"
2. ✅ All 4 CSS files exist on server
3. ✅ HTTP 200 response for CSS files

**Rollback triggers:**
- ❌ PM2 process not online → Automatic rollback
- ❌ CSS files missing → Automatic rollback
- ⚠️  HTTP verification failed → Warning only (may be temporary DNS/cache issue)

---

### Phase 8: Backup Rotation

**What happens:**
```bash
# Keep only last 10 backups
ssh acme "cd /var/www/vyxenai.com/pdev-backups && ls -t | tail -n +11 | xargs -r rm -rf"

# Delete backups older than 30 days
ssh acme "find /var/www/vyxenai.com/pdev-backups -type d -mtime +30 -delete"

# Delete old service backups (keep last 5)
ssh acme "cd /opt/services/pdev-live && ls -t server.js.bak-* | tail -n +6 | xargs -r rm -f"
```

**Why:** Prevent disk space exhaustion from old backups

**Retention policies:**
- Frontend backups: Keep 10 most recent
- Frontend backups: Delete if >30 days old
- Backend backups: Keep 5 most recent

---

### Phase 9: Record Deployment

**What happens:**
```bash
echo "$COMMIT_AFTER" | ssh acme "cat > /opt/services/pdev-live/.deployed_version"
```

**Why:** Track which commit is currently deployed

**File:** `/opt/services/pdev-live/.deployed_version`
**Content:** Git commit hash (e.g., `8e662d66f3a2c4b1d9e5f7a8c0b3d1e2f4a5c6b7`)

---

## Automatic Rollback

If deployment fails, update.sh automatically restores from backup:

```bash
echo "❌ PM2 process not online - triggering rollback"
echo "🔄 Rolling back..."

# Restore frontend files
ssh acme "cp $BACKUP_DIR/* /var/www/vyxenai.com/pdev/"

# Restore backend
ssh acme "cp /opt/services/pdev-live/server.js.bak-$TIMESTAMP /opt/services/pdev-live/server.js"

# Restart PM2
ssh acme "pm2 restart pdev-live"

exit 1
```

**Rollback scenarios:**
- PM2 process fails to start
- Required CSS files missing
- Deployment verification failures

---

## Post-Deployment Checklist

After successful deployment:

### 1. Cache Busting (MANDATORY)

```bash
/cache-bust https://vyxenai.com/pdev/
```

**Why:** Invalidate Cloudflare cache so users get new CSS/JS files

**What it does:**
- Purges Cloudflare cache for entire /pdev/live/ directory
- Clears Next.js cache if applicable
- Verifies cache purge succeeded

### 2. Browser Testing

**Test in browser:**
1. Navigate to https://vyxenai.com/pdev/
2. Hard refresh: `Ctrl+Shift+R` (Windows/Linux) or `Cmd+Shift+R` (Mac)
3. Open F12 Developer Tools → Console
4. Verify: **Zero CSS 404 errors**

### 3. Page Verification

Test all 4 pages:
- [ ] https://vyxenai.com/pdev/ (index.html - dashboard)
- [ ] https://vyxenai.com/pdev/session.html (session viewer)
- [ ] https://vyxenai.com/pdev/project.html (project viewer)
- [ ] https://vyxenai.com/pdev/live.html (live streaming)

**For each page:**
- ✅ Page loads without errors
- ✅ Styling renders correctly
- ✅ No 404 errors in F12 console
- ✅ CSS files load (Network tab shows 200 OK)

### 4. Backend Health Check

```bash
ssh acme 'pm2 logs pdev-live --lines 20'
```

**Verify:**
- ✅ No error messages in logs
- ✅ Process is running (uptime > 0)
- ✅ No restart loops

---

## Manual Deployment (Emergency Only)

If update.sh is unavailable:

```bash
# 1. SSH to production server
ssh acme

# 2. Backup current files
mkdir -p /var/www/vyxenai.com/pdev-backups/manual-$(date +%Y%m%d_%H%M%S)
cp /var/www/vyxenai.com/pdev/*.{html,css,js} /var/www/vyxenai.com/pdev-backups/manual-$(date +%Y%m%d_%H%M%S)/

# 3. From local machine, deploy frontend
rsync -avz --checksum frontend/ acme:/var/www/vyxenai.com/pdev/

# 4. Deploy backend
scp server/server.js acme:/opt/services/pdev-live/server.js

# 5. Restart PM2
ssh acme 'pm2 restart pdev-live'

# 6. Verify deployment
ssh acme 'pm2 status pdev-live'

# 7. Cache bust
/cache-bust https://vyxenai.com/pdev/
```

**⚠️  WARNING:** Manual deployment skips:
- Syntax validation
- Automatic rollback
- Deployment verification
- Backup rotation

**Use only when:** update.sh is broken or unavailable

---

## Troubleshooting

### Deployment Fails at Phase 3 (Syntax Validation)

**Symptom:** "❌ Syntax error in server.js"

**Fix:**
1. Run `node -c server/server.js` locally
2. Fix syntax errors
3. Commit and retry deployment

### Deployment Fails at Phase 6 (PM2 Restart)

**Symptom:** "❌ PM2 process not online"

**Debug:**
```bash
ssh acme 'pm2 logs pdev-live --lines 50'
ssh acme 'pm2 describe pdev-live'
```

**Common causes:**
- Port already in use
- Environment variable missing
- Database connection failure
- Permission issues

### CSS Files Return 404 After Deployment

**Symptom:** Browser F12 console shows "Failed to load resource: 404"

**Fix:**
1. Verify files exist: `ssh acme 'ls -la /var/www/vyxenai.com/pdev/*.css'`
2. Check permissions: `ssh acme 'ls -l /var/www/vyxenai.com/pdev/*.css'`
3. Run cache bust: `/cache-bust https://vyxenai.com/pdev/`
4. Hard refresh browser: `Ctrl+Shift+R`

### Backup Rotation Fails

**Symptom:** "rm: cannot remove ... Permission denied"

**Fix:**
```bash
ssh acme 'ls -la /var/www/vyxenai.com/pdev-backups/'
ssh acme 'sudo chown -R acme:acme /var/www/vyxenai.com/pdev-backups/'
```

---

## Production Environment

| Component | Location | Port |
|-----------|----------|------|
| Frontend | acme:/var/www/vyxenai.com/pdev/ | 443 (nginx) |
| Backend | acme:/opt/services/pdev-live/ | 3016 (internal) |
| Backups | acme:/var/www/vyxenai.com/pdev-backups/ | - |
| Logs | acme:/opt/services/pdev-live/logs/ | - |
| Deployment Log | dolovdev:~/pdev-live-deployment.log | - |

**Production URLs:**
- https://vyxenai.com/pdev/ (frontend)
- https://vyxenai.com/pdev/api/ (backend API)

**Authentication:**
- Username: `pdev`
- Password: `PdevLive0987@@`
- Auth type: HTTP Basic Authentication (.htpasswd)
- Auth file: `/var/www/vyxenai.com/.htpasswd_pdev`

---

## Deployment Logs

**Location:** `~/pdev-live-deployment.log`

**Contents:**
- Timestamp of deployment
- Git commit before/after
- Deployment phase progress
- Verification results
- Any errors or warnings

**View recent deployments:**
```bash
tail -100 ~/pdev-live-deployment.log
```

**View today's deployments:**
```bash
grep "$(date +%Y-%m-%d)" ~/pdev-live-deployment.log
```

---

## Partner Self-Hosted Deployment

Partner deployments use a different architecture (web-only, no desktop app):

### Initial Deployment

**Run the one-click installer:**
```bash
cd ~/projects/pdev-live/installer
sudo ./pdl-installer.sh
```

**Installer handles:**
1. ✅ System dependencies (Node.js 20.x, PostgreSQL 15, Nginx)
2. ✅ Database creation with migrations
3. ✅ Let's Encrypt SSL certificate
4. ✅ Firewall configuration (UFW)
5. ✅ Fail2Ban setup
6. ✅ PM2 service configuration
7. ✅ HTTP Basic Auth (nginx + Express)

### Post-Install Updates

**Update code:**
```bash
cd /opt/pdev-live
git pull origin main
```

**Validate syntax:**
```bash
node -c /opt/pdev-live/server/server.js
```

**Restart service:**
```bash
pm2 restart pdev-live
```

**Verify deployment:**
```bash
# Check PM2 status
pm2 list

# Check health endpoint
curl -u username:password https://your-domain.com/health

# Run security audit
cd /opt/pdev-live/installer
sudo ./security-audit.sh
```

### Partner Environment Variables

**File:** `/opt/pdev-live/server/.env`

**Critical settings:**
```bash
NODE_ENV=production
PORT=3016

# Partner domain (REQUIRED in production)
PDEV_BASE_URL=https://your-domain.com

# Static serving (REQUIRED for partners - nginx not serving)
PDEV_SERVE_STATIC=true
PDEV_FRONTEND_DIR=/opt/pdev-live/frontend

# Defense-in-depth auth (RECOMMENDED)
PDEV_HTTP_AUTH=true
PDEV_USERNAME=partner_username
PDEV_PASSWORD=secure_password

# Database credentials (generated during install)
PDEV_DB_HOST=localhost
PDEV_DB_PORT=5432
PDEV_DB_NAME=pdev_live
PDEV_DB_USER=pdev_app
PDEV_DB_PASSWORD=[GENERATED]

# Admin API key (generated during install)
PDEV_ADMIN_KEY=[GENERATED]
```

### Partner vs Walletsnack Deployment

| Aspect | Walletsnack | Partner |
|--------|-------------|---------|
| **Frontend Serving** | Nginx (`/var/www/`) | Express.js (`/opt/pdev-live/frontend/`) |
| **Desktop App** | Yes | No (web-only) |
| **Deployment Path** | `/var/www/vyxenai.com/pdev/` | `/opt/pdev-live/` |
| **Base URL** | `https://vyxenai.com/pdev/` | `https://partner-domain.com` |
| **HTTP Auth** | Nginx only | Nginx + Express (defense-in-depth) |
| **SSL** | Let's Encrypt | Let's Encrypt |
| **Update Method** | `./update.sh` via rsync | `git pull` + `pm2 restart` |
| **PM2 Config** | `ecosystem.config.js` | `ecosystem.config.js` |

### Partner Rollback Procedure

**If deployment fails:**

1. **Stop faulty service:**
   ```bash
   pm2 stop pdev-live
   ```

2. **Restore from git:**
   ```bash
   cd /opt/pdev-live
   git log --oneline -10  # Find last good commit
   git reset --hard <commit-hash>
   ```

3. **Restart service:**
   ```bash
   pm2 restart pdev-live
   ```

4. **Verify:**
   ```bash
   curl -u username:password https://your-domain.com/health
   ```

### Partner Database Backup

**Manual backup:**
```bash
sudo -u postgres pg_dump pdev_live > /var/backups/pdev_live_$(date +%Y%m%d_%H%M%S).sql
gzip /var/backups/pdev_live_*.sql
```

**Automated backup (cron):**
```bash
# Add to partner's crontab
0 2 * * * sudo -u postgres pg_dump pdev_live | gzip > /var/backups/pdev_live_$(date +\%Y\%m\%d).sql.gz
```

**Restore:**
```bash
gunzip < /var/backups/pdev_live_20260104.sql.gz | sudo -u postgres psql pdev_live
```

### Partner Monitoring

**Check logs:**
```bash
# PM2 logs
pm2 logs pdev-live --lines 100

# Nginx access logs
tail -f /var/log/nginx/pdev-access.log

# Nginx error logs
tail -f /var/log/nginx/pdev-error.log

# Fail2Ban status
sudo fail2ban-client status nginx-auth
```

**Check service health:**
```bash
# PM2 process status
pm2 status

# Nginx status
systemctl status nginx

# PostgreSQL status
systemctl status postgresql

# Firewall status
sudo ufw status
```

### Partner Troubleshooting

**Service won't start:**
```bash
# Check PM2 logs
pm2 logs pdev-live --err --lines 50

# Check environment variables
grep "PDEV_BASE_URL" /opt/pdev-live/server/.env

# Test server.js directly
cd /opt/pdev-live/server
node server.js
# (Ctrl+C to stop)
```

**SSL certificate issues:**
```bash
# Check certificate expiration
sudo certbot certificates

# Renew certificate
sudo certbot renew

# Test nginx config
sudo nginx -t
```

**Database connection failures:**
```bash
# Test database connection
sudo -u postgres psql -d pdev_live -c "SELECT 1;"

# Check database logs
sudo tail -50 /var/log/postgresql/postgresql-15-main.log
```

---

## Related Documentation

- [README.md](README.md) - Project overview and installation
- [installer/README.md](installer/README.md) - Self-hosted installation guide
- [installer/README-PARTNER.md](installer/README-PARTNER.md) - Partner deployment guide
- [update.sh](update.sh) - Deployment script source code (vyxenai)
