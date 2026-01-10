# PDev-Live Partner Installation Guide

**Version:** 1.0.0
**Last Updated:** 2026-01-05

---

## Installation Modes

PDev-Live supports two installation modes:

### Source Server (Full Stack)
Hosts the PDev-Live backend (database, nginx, PM2, API server) that receives data from project servers.

**When to use:** You want to host your own PDev-Live instance.

```bash
sudo ./pdl-installer.sh --domain pdev.yourdomain.com
```

### Project Server (Client Only)
Installs only the CLI client that posts data to a source server.

**When to use:** You have multiple project servers that need to report to a central source server.

```bash
sudo ./pdl-installer.sh --source-url https://pdev.yourdomain.com/pdev/api
```

---

## Quick Start

### Source Server Installation (Full Stack)

```bash
# Download installer package
wget https://vyxenai.com/pdev/install/pdev-partner-installer.tar.gz

# Extract
tar -xzf pdev-partner-installer.tar.gz
cd installer

# Install source server
sudo ./pdl-installer.sh --domain pdev.yourdomain.com
```

### Project Server Installation (Client Only)

```bash
# Download installer package (same package)
wget https://vyxenai.com/pdev/install/pdev-partner-installer.tar.gz

# Extract
tar -xzf pdev-partner-installer.tar.gz
cd installer

# Install project server client
sudo ./pdl-installer.sh --source-url https://pdev.yourdomain.com/pdev/api
```

---

## Prerequisites

### Source Server Requirements

- **OS:** Ubuntu 20.04+ or Debian 11+
- **RAM:** 1GB minimum (2GB recommended)
- **Disk:** 2GB free space minimum
- **Domain:** Registered domain pointed to your server IP

### Project Server Requirements

- **OS:** Any Linux with bash, curl
- **RAM:** 256MB minimum
- **Disk:** 50MB free space
- **Network:** Access to source server URL

### Required Software (Source Server Only)

Install these BEFORE running the source server installer:

**1. Node.js 18+**
```bash
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt-get install -y nodejs
node -v  # Should show v18 or higher
```

**2. PostgreSQL 14+**
```bash
sudo apt-get install -y postgresql postgresql-contrib
psql --version  # Should show 14 or higher
```

**3. nginx**
```bash
sudo apt-get install -y nginx
nginx -v
```

**4. Let's Encrypt SSL Certificate**
```bash
sudo apt-get install -y certbot python3-certbot-nginx
sudo certbot certonly --nginx -d pdev.yourdomain.com
```

**5. apache2-utils (for htpasswd)**
```bash
sudo apt-get install -y apache2-utils
```

**Project Server:** No prerequisites required (curl and bash included in all Linux distros)

---

## Installation

### Step 1: Download Package

```bash
wget https://vyxenai.com/pdev/install/pdev-partner-installer.tar.gz
```

### Step 2: Extract Package

```bash
tar -xzf pdev-partner-installer.tar.gz
cd installer
```

**Package contents:**
- `pdl-installer.sh` - Main installer script
- `nginx-partner-template.conf` - Nginx configuration template
- `.env.partner.template` - Environment variable template
- `security-audit.sh` - Post-install security validation
- `migrations/` - Database migration files
- `README-PARTNER.md` - This file

### Step 3: Run Installer

**Choose Your Mode:**

#### Source Server (Full Stack)

**Basic installation:**
```bash
sudo ./pdl-installer.sh --domain pdev.yourdomain.com
```

**Advanced options:**
```bash
sudo ./pdl-installer.sh \
  --domain pdev.yourdomain.com \
  --http-user myuser \
  --http-password mypassword \
  --install-dir /opt/pdev-live \
  --non-interactive
```

**Test with dry-run (no changes made):**
```bash
sudo ./pdl-installer.sh --domain pdev.yourdomain.com --dry-run
```

#### Project Server (Client Only)

**Basic installation:**
```bash
sudo ./pdl-installer.sh --source-url https://pdev.yourdomain.com/pdev/api
```

**Test with dry-run (no changes made):**
```bash
sudo ./pdl-installer.sh --source-url https://pdev.yourdomain.com/pdev/api --dry-run
```

### Step 4: Save Credentials (Source Mode Only)

**CRITICAL (SOURCE MODE ONLY):** The installer displays credentials ONCE at the end. Save them immediately:

- **URL:** https://pdev.yourdomain.com
- **HTTP Auth Username**
- **HTTP Auth Password**
- **Database Password**
- **Admin API Key**

These are stored in:
- `~/.pdev-live-config` (client URL configuration, 600 permissions)
- `/opt/pdev-live/.env` (600 permissions, owner-only)
- `/etc/nginx/.htpasswd` (644 permissions, root:www-data)

**Project Mode:** No credentials generated - client posts to source server using source server's credentials

---

## Installer Options

```
REQUIRED (choose one):
  --domain DOMAIN          Source server domain (installs full stack)
  --source-url URL         Source server API URL (installs client only)

OPTIONAL (source mode only):
  --db-password PASSWORD   PostgreSQL password (default: auto-generated)
  --admin-key KEY          Admin API key (default: auto-generated)
  --http-user USERNAME     HTTP auth username (default: admin)
  --http-password PASSWORD HTTP auth password (default: auto-generated)
  --install-dir PATH       Installation directory (default: /opt/pdev-live)

OPTIONAL (all modes):
  --mode MODE              Explicit mode override (source|project) [auto-detected]
  --dry-run                Preview changes without making them
  --non-interactive        No prompts (use defaults)
  --force                  Overwrite existing installation
  --help                   Show help message

EXAMPLES:
  # Source server (full stack on acme/walletsnack.com)
  sudo ./pdl-installer.sh --domain walletsnack.com

  # Project server (client only on ittz, posts to walletsnack.com)
  sudo ./pdl-installer.sh --source-url https://walletsnack.com/pdev/api
```

---

## Post-Installation

### Verify Installation

**Check PM2 status:**
```bash
pm2 status
# Should show "pdev-live" with status "online"
```

**Check logs:**
```bash
pm2 logs pdev-live --lines 50
```

**Test HTTP health endpoint:**
```bash
curl http://localhost:3016/health
# Should return {"status":"healthy"}
```

**Test HTTPS with authentication:**
```bash
curl -u username:password https://pdev.yourdomain.com/health
# Should return {"status":"healthy"}
```

### Configure Desktop Client

1. Open PDev Live desktop app
2. Go to Settings → Server URL
3. Enter: `https://pdev.yourdomain.com`
4. Enter HTTP auth credentials
5. Test connection

---

## Security

### Dual-Layer Authentication

PDev-Live uses defense-in-depth authentication:

**Layer 1 (nginx):** HTTP Basic Auth via .htpasswd
**Layer 2 (Express.js):** Application-level HTTP Basic Auth

Both layers must be configured for maximum security.

### SSL/TLS

- HTTPS enforced (HTTP redirects to HTTPS)
- TLS 1.2 and 1.3 only
- Strong cipher suites
- HSTS enabled (1-year max-age)

### Firewall Recommendations

```bash
# Allow SSH, HTTP, HTTPS
sudo ufw allow 22/tcp
sudo ufw allow 80/tcp
sudo ufw allow 443/tcp

# Deny direct access to backend (nginx proxy only)
sudo ufw deny 3016/tcp

# Enable firewall
sudo ufw enable
```

### Fail2Ban (Recommended)

```bash
sudo apt-get install -y fail2ban
sudo systemctl enable fail2ban
sudo systemctl start fail2ban
```

---

## Troubleshooting

### Installation Fails

**Check logs:**
```bash
# Installer log (created in /tmp/)
tail -f /tmp/pdev-partner-installer-*.log
```

**Common issues:**

**1. SSL certificate not found**
```bash
# Run certbot first
sudo certbot certonly --nginx -d pdev.yourdomain.com
```

**2. Port 3016 already in use**
```bash
# Find conflicting process
lsof -i:3016

# Kill it
kill -9 <PID>
```

**3. PostgreSQL not running**
```bash
sudo systemctl start postgresql
sudo systemctl enable postgresql
```

**4. Node.js version too old**
```bash
# Install Node.js 18+
curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
sudo apt-get install -y nodejs
```

### Service Not Starting

**Check PM2 status:**
```bash
pm2 status
pm2 logs pdev-live --err
```

**Restart service:**
```bash
pm2 restart pdev-live
```

**Check .env file exists:**
```bash
ls -la /opt/pdev-live/.env
# Should show: -rw------- (600 permissions)
```

### HTTPS Not Working

**Check nginx configuration:**
```bash
nginx -t
```

**Check SSL certificate:**
```bash
ls -la /etc/letsencrypt/live/pdev.yourdomain.com/
```

**Reload nginx:**
```bash
nginx -s reload
```

### HTTP 401 Always (Can't Login)

**Check .htpasswd exists:**
```bash
ls -la /etc/nginx/.htpasswd
```

**Verify credentials:**
```bash
# Test with correct credentials
curl -u username:password https://pdev.yourdomain.com/health
```

**Reset password:**
```bash
htpasswd -c /etc/nginx/.htpasswd newusername
chmod 644 /etc/nginx/.htpasswd
chown root:www-data /etc/nginx/.htpasswd
nginx -s reload
```

---

## Maintenance

### Update SSL Certificate

```bash
# Auto-renew (run monthly via cron)
sudo certbot renew

# Manual renewal
sudo certbot certonly --nginx -d pdev.yourdomain.com --force-renewal

# Reload nginx after renewal
nginx -s reload
```

### Backup Database

```bash
# Backup
pg_dump -U pdev_app pdev_live > pdev_backup_$(date +%Y%m%d).sql

# Restore
sudo -u postgres psql -d pdev_live < pdev_backup_20260104.sql
```

### Backup Configuration

```bash
# Backup .env
cp /opt/pdev-live/.env /tmp/pdev_backup.env

# Backup nginx config
cp /etc/nginx/sites-available/pdev-live /tmp/nginx_backup.conf
```

### Update PDev-Live

```bash
# Download new installer
wget https://vyxenai.com/pdev/install/pdev-partner-installer.tar.gz
tar -xzf pdev-partner-installer.tar.gz
cd installer

# Backup current installation
pg_dump -U pdev_app pdev_live > /tmp/pdev_backup.sql
cp /opt/pdev-live/.env /tmp/pdev_backup.env

# Reinstall with --force
sudo ./pdl-installer.sh --domain pdev.yourdomain.com --force
```

---

## Uninstallation

### Complete Removal

```bash
# Stop PM2 process
pm2 delete pdev-live
pm2 save

# Remove installation directory
sudo rm -rf /opt/pdev-live

# Remove nginx configuration
sudo rm /etc/nginx/sites-enabled/pdev-live
sudo rm /etc/nginx/sites-available/pdev-live
sudo rm /etc/nginx/.htpasswd
sudo nginx -s reload

# Remove database (optional)
sudo -u postgres psql -c "DROP DATABASE IF EXISTS pdev_live;"
sudo -u postgres psql -c "DROP USER IF EXISTS pdev_app;"
```

---

## Support

### Documentation

- **Installation Guide:** This file
- **Disaster Recovery:** `~/claude-tools/runbooks/RUNBOOK_PDEV-LIVE_20260101.md`
- **Security Audit:** Run `sudo ./security-audit.sh` after installation

### Common Commands

```bash
# Check status
pm2 status

# View logs
pm2 logs pdev-live

# Restart service
pm2 restart pdev-live

# Test health
curl http://localhost:3016/health

# Test HTTPS
curl -u username:password https://pdev.yourdomain.com/health
```

### Recovery Procedures

See partner recovery procedures in the disaster recovery runbook:
`~/claude-tools/runbooks/RUNBOOK_PDEV-LIVE_20260101.md`

Covers:
- Service restart
- Database recovery
- SSL certificate issues
- HTTP Basic Auth reset
- Port conflicts
- Complete system rebuild

---

## Architecture

**Components:**
- **Frontend:** Express.js serves static HTML/CSS/JS files
- **Backend:** Node.js Express.js API server (port 3016)
- **Database:** PostgreSQL 14+ (localhost only)
- **Proxy:** nginx with SSL termination and HTTP Basic Auth
- **Process Manager:** PM2 with auto-restart on failure
- **Security:** Dual-layer HTTP Basic Auth (nginx + Express)

**File Locations:**
- Application: `/opt/pdev-live/`
- Configuration: `/opt/pdev-live/.env`
- Nginx config: `/etc/nginx/sites-available/pdev-live`
- HTTP auth: `/etc/nginx/.htpasswd`
- Logs: `pm2 logs pdev-live`
- Database: PostgreSQL `pdev_live` database

---

**Installation Complete!** Access your PDev-Live instance at `https://pdev.yourdomain.com`
