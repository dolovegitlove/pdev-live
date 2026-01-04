# PDev Live Self-Hosted Installer

One-command installation for PDev Live on your own server.

## Quick Start

### Linux/macOS
```bash
./install.sh
```

### Windows (PowerShell as Administrator)
```powershell
.\install.ps1
```

## Requirements

The installer will automatically detect and offer to install:
- **Node.js 18+**
- **PostgreSQL 14+**
- **PM2**

## Installation Options

### Linux/macOS

```bash
# Interactive (default)
./install.sh

# Accept all defaults
./install.sh --yes

# Custom installation directory
./install.sh --install-dir /opt/pdev

# Custom port
./install.sh --port 3020

# Non-interactive mode
./install.sh --non-interactive --yes
```

### Windows

```powershell
# Interactive (default)
.\install.ps1

# Accept all defaults
.\install.ps1 -AcceptAll

# Custom installation directory
.\install.ps1 -InstallDir "D:\pdev"

# Custom port
.\install.ps1 -Port 3020
```

## What Gets Installed

```
/opt/services/pdev-live/           # Linux/macOS default
C:\pdev-live\                      # Windows default
├── server.js                      # Main server
├── package.json                   # Dependencies
├── ecosystem.config.js            # PM2 configuration
├── .env                           # Credentials (chmod 600)
├── logs/                          # Application logs
│   ├── out.log
│   └── error.log
└── frontend/                      # Static files (optional)
```

## Post-Installation

### Check Status
```bash
pm2 status pdev-live
```

### View Logs
```bash
pm2 logs pdev-live
```

### Restart Service
```bash
pm2 restart pdev-live
```

### Health Check
```bash
curl http://localhost:3016/health
```

## Configuration

All configuration is stored in `.env`:

```env
PDEV_DB_HOST=localhost
PDEV_DB_PORT=5432
PDEV_DB_NAME=pdev_live
PDEV_DB_USER=pdev_app
PDEV_DB_PASSWORD=<generated>
PORT=3016
PDEV_ADMIN_KEY=<generated>
```

## Deployment Scripts

PDev Live has **two deployment scripts** - make sure you use the correct one:

### pdev-update.sh (Self-Hosted Auto-Updater)
- **Purpose:** Updates self-hosted installations
- **Usage:** `./pdev-update.sh` (run on your own server)
- **Source:** Pulls updates from walletsnack.com/pdev/api/version
- **Location:** `installer/pdev-update.sh`
- **Use When:** You installed PDev Live via `install.sh` and want to update to latest version

### update.sh (Production Deployment Script)
- **Purpose:** Deploy changes to production (walletsnack.com)
- **Usage:** `./update.sh` (run from laptop, deploys to acme server)
- **Source:** Deploys from local git repository
- **Location:** Root `update.sh`
- **Use When:** You're a PDev Live maintainer deploying code changes

**Most users need:** `pdev-update.sh` (self-hosted updater)
**Maintainers need:** `update.sh` (production deployment)

## Frontend Deployment (Optional)

PDev Live can run in two modes:

### API-Only Mode (Default)
- Server provides API endpoints only
- No frontend HTML/CSS/JS served
- Clients use their own frontend or API directly
- Smaller disk footprint
- No nginx configuration needed

### Full Web Interface Mode
- Server provides API + frontend files
- Users access web interface at configured URL
- Requires nginx reverse proxy (see below)
- Recommended for production deployments

To deploy frontend files:

```bash
# Copy frontend to your web server directory
cp -r frontend/* /var/www/html/pdev-live/

# Or use symbolic link
ln -s /opt/services/pdev-live/frontend /var/www/html/pdev-live
```

**Frontend CSS Architecture:**

PDev Live uses a multi-file CSS structure:
- **pdev-live.css** (12KB) - Shared base styles for all pages
- **page-specific.css** files - Additional styles for session/project/index pages
- **live.html** uses only base CSS (no page-specific file)

See main [README.md](../README.md#css-architecture) for full CSS architecture documentation.

## Nginx Reverse Proxy (Optional)

```nginx
location /pdev/api/ {
    proxy_pass http://localhost:3016/;
    proxy_http_version 1.1;
    proxy_set_header Connection "";
    proxy_buffering off;
    proxy_cache off;
    proxy_read_timeout 86400s;
}
```

## Troubleshooting

### Service won't start
```bash
pm2 logs pdev-live --lines 50
```

### Database connection issues
```bash
# Test connection
PGPASSWORD=$PDEV_DB_PASSWORD psql -h localhost -U pdev_app -d pdev_live -c "SELECT 1"
```

### Permission issues
```bash
# Check .env permissions (should be 600)
ls -la /opt/services/pdev-live/.env
```

## Uninstall

```bash
# Stop and remove PM2 process
pm2 delete pdev-live
pm2 save

# Remove files
sudo rm -rf /opt/services/pdev-live

# Remove database (optional)
sudo -u postgres dropdb pdev_live
sudo -u postgres dropuser pdev_app
```
