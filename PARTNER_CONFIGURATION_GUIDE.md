# PDev-Live Partner Configuration Guide

**Last Updated:** 2026-01-08

This guide explains how to configure PDev-Live for your organization's infrastructure.

---

## Overview

PDev-Live has been refactored to eliminate hardcoded references to:
- `walletsnack.com` domain
- `acme` server names
- Specific deployment paths

All partner-specific values are now configurable via environment variables and `.env` files.

---

## Quick Start

### 1. Copy Configuration Template

```bash
cd ~/projects/pdev-live
cp .env.partner.example .env
```

### 2. Edit Configuration

Open `.env` and customize these critical values:

```bash
# Partner Identity
PARTNER_DOMAIN=your-company.com
PARTNER_NAME="Your Company Name"
PARTNER_SERVER_NAME=prod-01

# API Configuration
PDEV_LIVE_URL=https://your-company.com/pdev/api
PDEV_BASE_URL=https://your-company.com/pdev

# Server Inventory
VALID_SERVERS=prod-01,prod-02,staging,dev

# Database
DB_PASSWORD=YOUR_SECURE_PASSWORD_HERE

# Authentication
PDEV_AUTH_PASSWORD=YOUR_SECURE_PASSWORD_HERE
SESSION_SECRET=$(openssl rand -base64 32)
```

### 3. Deploy Configuration

**Option A: Server Installation**
```bash
# Copy .env to server
scp .env your-server:/opt/services/pdev-live/.env

# Restart services
ssh your-server "pm2 restart pdev-live"
```

**Option B: Automated Installer**
```bash
cd installer
sudo ./pdl-installer.sh --domain your-company.com
```

---

## Configuration Reference

### Partner Identity

| Variable | Description | Example |
|----------|-------------|---------|
| `PARTNER_DOMAIN` | Your company's domain | `acme-corp.com` |
| `PARTNER_NAME` | Display name | `ACME Corporation` |
| `PARTNER_SERVER_NAME` | Primary server identifier | `prod-server-01` |
| `PARTNER_TIMEZONE` | Timezone for logs/timestamps | `America/New_York` |

### API Configuration

| Variable | Description | Default |
|----------|-------------|---------|
| `PDEV_LIVE_URL` | Full API URL | `https://${PARTNER_DOMAIN}/pdev/api` |
| `PDEV_BASE_URL` | Base URL for frontend | `https://${PARTNER_DOMAIN}/pdev` |
| `PDEV_API_PORT` | Internal API port | `3077` |
| `PDEV_API_HOST` | Bind address | `0.0.0.0` |

### Server Inventory

| Variable | Description | Example |
|----------|-------------|---------|
| `VALID_SERVERS` | Comma-separated server names | `prod-01,prod-02,staging` |
| `ALLOWED_IPS` | IP whitelist for API access | `127.0.0.1,10.0.1.5` |

### Database Configuration

| Variable | Description | Default |
|----------|-------------|---------|
| `DB_HOST` | PostgreSQL host | `localhost` |
| `DB_PORT` | PostgreSQL port | `5432` |
| `DB_NAME` | Database name | `pdev_live` |
| `DB_USER` | Database user | `pdev_user` |
| `DB_PASSWORD` | Database password | ⚠️ **REQUIRED** |

**Alternative:** Use `DATABASE_URL` connection string:
```bash
DATABASE_URL=postgresql://user:pass@host:5432/dbname
```

### Deployment Paths

| Variable | Description | Default |
|----------|-------------|---------|
| `DEPLOY_USER` | SSH user for deployment | `deploy` |
| `FRONTEND_DEPLOY_PATH` | Frontend files directory | `/var/www/${PARTNER_DOMAIN}/pdev` |
| `FRONTEND_BACKUP_PATH` | Backup directory | `/var/www/${PARTNER_DOMAIN}/pdev-backups` |
| `BACKEND_SERVICE_PATH` | Backend service directory | `/opt/services/pdev-live` |
| `LOG_PATH` | Log file directory | `${BACKEND_SERVICE_PATH}/logs` |

### SSL/TLS Configuration

| Variable | Description | Auto-Generated |
|----------|-------------|----------------|
| `SSL_CERT_PATH` | SSL certificate path | `/etc/letsencrypt/live/${PARTNER_DOMAIN}/fullchain.pem` |
| `SSL_KEY_PATH` | SSL private key path | `/etc/letsencrypt/live/${PARTNER_DOMAIN}/privkey.pem` |

### Authentication

| Variable | Description | Default |
|----------|-------------|---------|
| `PDEV_AUTH_USER` | HTTP Basic Auth username | `pdev` |
| `PDEV_AUTH_PASSWORD` | HTTP Basic Auth password | ⚠️ **REQUIRED** |
| `SESSION_SECRET` | Express session secret | ⚠️ **REQUIRED** |

**Generate secure secrets:**
```bash
openssl rand -base64 32  # For SESSION_SECRET
openssl rand -base64 24  # For PDEV_AUTH_PASSWORD
```

### Desktop Client

| Variable | Description | Default |
|----------|-------------|---------|
| `DESKTOP_HOMEPAGE` | Electron app homepage | `https://${PARTNER_DOMAIN}/pdev/live/` |
| `DESKTOP_UPDATE_URL` | Auto-update server | `https://${PARTNER_DOMAIN}/pdev/releases/` |

**Note:** Desktop package.json must be updated manually before building:
```json
{
  "homepage": "https://your-company.com/pdev/live/",
  "publish": {
    "url": "https://your-company.com/pdev/releases/"
  }
}
```

### Feature Flags

| Variable | Description | Default |
|----------|-------------|---------|
| `ENABLE_AUTO_UPDATES` | Enable desktop auto-updates | `true` |
| `ENABLE_TELEMETRY` | Enable usage telemetry | `false` |
| `ENABLE_DEBUG_MODE` | Enable debug logging | `false` |

### Backup Retention

| Variable | Description | Default |
|----------|-------------|---------|
| `BACKUP_KEEP_DAYS` | Days to retain backups | `30` |
| `BACKUP_MAX_COUNT` | Maximum backup count | `10` |

### PM2 Configuration

| Variable | Description | Default |
|----------|-------------|---------|
| `PM2_APP_NAME` | PM2 process name | `pdev-live` |
| `PM2_INSTANCES` | Number of instances | `1` |
| `PM2_MAX_MEMORY_RESTART` | Memory limit | `512M` |

---

## Configuration Loading Order

PDev-Live loads configuration in this priority (highest to lowest):

1. **Environment variables** (set in shell or PM2 ecosystem)
2. **`.env` file** (in project root)
3. **Default values** (hardcoded in `config.js`)

**Example:**
```bash
# .env file has PARTNER_DOMAIN=staging.example.com
# Shell has: export PARTNER_DOMAIN=production.example.com
# Result: Uses production.example.com (env var wins)
```

---

## Validation

After configuration, verify setup:

### 1. Check Configuration Load
```bash
cd ~/projects/pdev-live
node -e "const cfg = require('./config'); console.log(cfg.partner);"
```

**Expected output:**
```json
{
  "domain": "your-company.com",
  "name": "Your Company Name",
  "serverName": "prod-01",
  "timezone": "America/New_York"
}
```

### 2. Verify Server Configuration
```bash
ssh your-server "cd /opt/services/pdev-live && node -e \"require('./server/server.js')\""
```

Should show no errors about missing configuration.

### 3. Test API Endpoint
```bash
curl -I https://your-company.com/pdev/api/health
```

**Expected:** `200 OK`

### 4. Test Frontend
```bash
curl -I https://your-company.com/pdev/live/
```

**Expected:** `200 OK` (may require HTTP Basic Auth)

---

## Common Issues

### Issue: Database Connection Failed
**Symptoms:** PM2 logs show `ECONNREFUSED` or `authentication failed`

**Fix:**
```bash
# Verify PostgreSQL is running
ssh your-server "systemctl status postgresql"

# Test connection manually
ssh your-server "psql -h localhost -U pdev_user -d pdev_live -c 'SELECT 1;'"

# Check .env has correct DB_PASSWORD
ssh your-server "cat /opt/services/pdev-live/.env | grep DB_PASSWORD"
```

### Issue: HTTP Basic Auth Not Working
**Symptoms:** Browser keeps prompting for credentials

**Fix:**
```bash
# Verify credentials in nginx config
ssh your-server "cat /etc/nginx/sites-enabled/pdev-live | grep auth_basic"

# Regenerate htpasswd file
ssh your-server "echo -n 'pdev:' | sudo tee /etc/nginx/.htpasswd-pdev"
ssh your-server "openssl passwd -apr1 'YOUR_PASSWORD' | sudo tee -a /etc/nginx/.htpasswd-pdev"
ssh your-server "sudo systemctl reload nginx"
```

### Issue: 502 Bad Gateway
**Symptoms:** Nginx shows 502 error

**Fix:**
```bash
# Check PM2 status
ssh your-server "pm2 status pdev-live"

# Check logs
ssh your-server "pm2 logs pdev-live --lines 50"

# Restart service
ssh your-server "pm2 restart pdev-live"
```

### Issue: Desktop Client Can't Connect
**Symptoms:** Desktop app shows "Connection failed"

**Fix:**
```bash
# Verify package.json has correct URL
cat ~/projects/pdev-live/desktop/package.json | grep homepage

# Update and rebuild
cd ~/projects/pdev-live/desktop
npm run build
```

---

## Deployment Workflow

### Initial Setup (New Partner)

1. **Configure .env**
   ```bash
   cd ~/projects/pdev-live
   cp .env.partner.example .env
   nano .env  # Edit all PARTNER_* and *_PASSWORD values
   ```

2. **Run Installer**
   ```bash
   cd installer
   sudo ./pdl-installer.sh --domain your-company.com --non-interactive
   ```

3. **Deploy Configuration**
   ```bash
   scp .env your-server:/opt/services/pdev-live/.env
   ssh your-server "pm2 restart pdev-live"
   ```

4. **Verify Installation**
   ```bash
   curl https://your-company.com/pdev/api/health
   curl https://your-company.com/pdev/live/
   ```

### Updating Configuration (Existing Installation)

1. **Edit .env Locally**
   ```bash
   nano ~/projects/pdev-live/.env
   ```

2. **Deploy Changes**
   ```bash
   scp .env your-server:/opt/services/pdev-live/.env
   ssh your-server "pm2 restart pdev-live"
   ```

3. **Verify**
   ```bash
   ssh your-server "pm2 logs pdev-live --lines 20"
   ```

---

## Security Best Practices

### 1. Use Strong Passwords
```bash
# Generate secure passwords (min 32 characters)
openssl rand -base64 32
```

### 2. Restrict Database Access
```bash
# PostgreSQL should only accept local connections
# /etc/postgresql/*/main/pg_hba.conf
local   pdev_live   pdev_user   scram-sha-256
host    pdev_live   pdev_user   127.0.0.1/32   scram-sha-256
```

### 3. Secure .env File Permissions
```bash
ssh your-server "chmod 600 /opt/services/pdev-live/.env"
ssh your-server "chown pdev-user:pdev-user /opt/services/pdev-live/.env"
```

### 4. Use HTTP Basic Auth + SSL
```bash
# Nginx config should have:
auth_basic "PDev Live";
auth_basic_user_file /etc/nginx/.htpasswd-pdev;
ssl_protocols TLSv1.2 TLSv1.3;
```

### 5. Restrict API Access by IP
```bash
# In .env, limit ALLOWED_IPS to trusted servers
ALLOWED_IPS=127.0.0.1,::1,10.0.1.5,10.0.1.6
```

---

## Environment-Specific Configurations

### Development Environment
```bash
# .env.development
NODE_ENV=development
PARTNER_DOMAIN=localhost
PDEV_LIVE_URL=http://localhost:3077
ENABLE_DEBUG_MODE=true
DB_HOST=localhost
```

### Staging Environment
```bash
# .env.staging
NODE_ENV=staging
PARTNER_DOMAIN=staging.your-company.com
PDEV_LIVE_URL=https://staging.your-company.com/pdev/api
ENABLE_TELEMETRY=true
```

### Production Environment
```bash
# .env.production
NODE_ENV=production
PARTNER_DOMAIN=your-company.com
PDEV_LIVE_URL=https://your-company.com/pdev/api
ENABLE_AUTO_UPDATES=true
ENABLE_TELEMETRY=false
```

**Load specific environment:**
```bash
NODE_ENV=staging pm2 start ecosystem.config.js
```

---

## Client-Side Configuration

### CLI Client (`client.sh`)

The CLI client auto-detects configuration from:

1. **Environment variable:**
   ```bash
   export PDEV_LIVE_URL=https://your-company.com/pdev/api
   export PDEV_BASE_URL=https://your-company.com/pdev
   ```

2. **Config file (`~/.pdev-live-config`):**
   ```bash
   cat > ~/.pdev-live-config <<EOF
   PDEV_LIVE_URL=https://your-company.com/pdev/api
   PDEV_BASE_URL=https://your-company.com/pdev
   PDEV_TOKEN=your-server-token-here
   EOF
   chmod 600 ~/.pdev-live-config
   ```

3. **Installer auto-configuration:**
   ```bash
   ~/projects/pdev-live/installer/pdl-installer.sh --domain your-company.com
   ```

### Server Auto-Detection

The client detects server name from hostname. To override:

```bash
# Override server detection
export PARTNER_SERVER_NAME=my-custom-name
export PDEV_SERVER=my-custom-name

# Then run commands
/idea "my project"
```

---

## Migration from Hardcoded Setup

If upgrading from pre-configuration version:

### 1. Backup Existing Installation
```bash
ssh your-server "tar -czf /tmp/pdev-live-backup.tar.gz /opt/services/pdev-live /etc/nginx/sites-enabled/pdev-live"
scp your-server:/tmp/pdev-live-backup.tar.gz ~/backups/
```

### 2. Create .env from Current Settings
```bash
cd ~/projects/pdev-live
cat > .env <<EOF
PARTNER_DOMAIN=$(ssh your-server "hostname -f")
PARTNER_SERVER_NAME=$(ssh your-server "hostname -s")
DB_PASSWORD=$(ssh your-server "grep DB_PASSWORD /opt/services/pdev-live/.env" || echo "")
# ... copy other values
EOF
```

### 3. Deploy Updated Code
```bash
cd ~/projects/pdev-live
git pull origin main
npm install
scp .env your-server:/opt/services/pdev-live/.env
scp config.js your-server:/opt/services/pdev-live/config.js
scp server/server.js your-server:/opt/services/pdev-live/server/server.js
ssh your-server "pm2 restart pdev-live"
```

### 4. Verify Migration
```bash
# Check logs for errors
ssh your-server "pm2 logs pdev-live --lines 50"

# Test API
curl https://your-company.com/pdev/api/health

# Test session creation
/idea "test-migration-project"
```

---

## Support

**Documentation:** `~/projects/pdev-live/README.md`
**Troubleshooting:** `~/projects/pdev-live/DEPLOYMENT.md`
**Installer:** `~/projects/pdev-live/installer/README-PARTNER.md`

**Quick Health Check:**
```bash
# Run comprehensive validation
cd ~/projects/pdev-live
./scripts/health-check.sh
```

---

**Document Owner:** PDev-Live Team
**Version:** 2.0 (Configuration-Ready)
**Last Updated:** 2026-01-08
