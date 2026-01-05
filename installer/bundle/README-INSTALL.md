# PDev Live - Complete Installation Bundle

**Version:** 1.0.0
**Bundle Date:** 2026-01-04
**Installation Type:** Bundled Desktop + Server

---

## 🎯 What You're Installing

This bundle installs **both** components of PDev Live in one coordinated process:

1. **Desktop App (PDev Live.app)** - Viewer application on your local machine
2. **Server (pdev-live-server)** - Backend API + database on target server

**Result:** A complete, production-ready PDev Live system with zero manual configuration.

---

## 📋 Prerequisites

### On Your Computer (Where You Run This Installer)
- macOS, Linux, or Windows (WSL/Git Bash)
- curl (for downloading files)
- ssh (for remote server access)
- 500MB free disk space

### On Target Server (Where PDev Server Will Run)
- Linux server with SSH access
- Node.js 18+ installed
- PostgreSQL 14+ installed and running
- PM2 process manager (`npm install -g pm2`)
- Port 3016 available

---

## ⚡ Quick Start

### Step 1: Extract This Bundle
```bash
unzip pdev-complete-v1.0.0.zip
cd pdev-live-bundle
```

### Step 2: Run Bundled Installer (Interactive Mode)
```bash
./pdev-bundled-installer.sh
```

The installer will:
1. Ask where to install the server (localhost or remote)
2. Verify SSH access (if remote)
3. Install server components
4. Download and install desktop app
5. Configure desktop app to connect to server
6. Verify installation success

**Estimated time:** 5-10 minutes

---

## 🎮 Installation Modes

### Mode A: Local Development (Server on This Machine)
```bash
./pdev-bundled-installer.sh --server-host localhost
```

**Use When:**
- Testing PDev Live
- Development environment
- Single-user setup

**Installs:**
- Desktop app: This machine
- Server: This machine (localhost:3016)

---

### Mode B: Remote Production Server
```bash
./pdev-bundled-installer.sh --server-host user@server.com
```

**Use When:**
- Production deployment
- Multi-user environment
- Team access required

**Installs:**
- Desktop app: This machine
- Server: Remote server (server.com:3016)

**Requirements:**
- SSH key authentication already configured
- Run: `ssh-copy-id user@server.com` first

---

### Mode C: Non-Interactive (Automation)
```bash
./pdev-bundled-installer.sh --non-interactive --server-host acme
```

**Use When:**
- Automated deployments
- CI/CD pipelines
- No user interaction possible

**Requirements:**
- `--server-host` must be specified
- SSH keys must be pre-configured
- Server prerequisites already installed

---

## 📦 What's In This Bundle

```
pdev-live-bundle/
├── pdev-bundled-installer.sh  # Bundled orchestrator script (THIS IS THE MAIN FILE)
├── install.sh                  # Server installer (called by bundled installer)
├── README-INSTALL.md          # This file
├── docs/
│   ├── TROUBLESHOOTING.md     # Common issues and fixes
│   └── ROLLBACK.md            # How to revert failed installation
└── desktop/                   # Desktop binaries downloaded automatically
    └── (binaries downloaded from vyxenai.com/pdev/releases/)
```

**Note:** Desktop app binaries (DMG/exe/deb) are **not** included in this bundle.
They are downloaded automatically during installation from:
- `https://vyxenai.com/pdev/releases/PDev-Live-1.0.0.dmg` (macOS)
- `https://vyxenai.com/pdev/releases/PDev-Live-1.0.0.exe` (Windows)
- `https://vyxenai.com/pdev/releases/PDev-Live-1.0.0.deb` (Linux)

---

## 🔧 Advanced Options

### Install Specific Version
```bash
./pdev-bundled-installer.sh --version 1.2.3 --server-host acme
```

### View All Options
```bash
./pdev-bundled-installer.sh --help
```

---

## ✅ Post-Installation Verification

After installation completes, verify everything works:

### Test 1: Server Health Check
```bash
curl http://localhost:3016/health
# Or for remote:
curl http://your-server.com:3016/health

# Expected output:
# {"status":"healthy","database":"connected"}
```

### Test 2: Desktop App Launch
1. Open "PDev Live" from Applications (macOS) or app menu (Linux)
2. Should connect to server automatically
3. Dashboard should load with "No active sessions" message

### Test 3: PM2 Status
```bash
# On server:
pm2 status pdev-live-server

# Expected:
# Status: online
# Restarts: 0
# Uptime: 1m
```

---

## 🚨 Troubleshooting

### Installation Failed Mid-Process

**Problem:** Script exited with error
**Solution:**
1. Check log file (shown in error message)
2. Rollback: Re-run installer with `--rollback` flag
3. See `docs/TROUBLESHOOTING.md`

### Desktop App Won't Connect

**Problem:** "Cannot connect to server" error
**Solution:**
1. Verify server is running: `pm2 status pdev-live-server`
2. Check config file points to correct server:
   - macOS: `~/Library/Application Support/PDev Live/config.json`
   - Linux: `~/.config/pdev-live/config.json`
3. Test server health: `curl http://SERVER_URL:3016/health`

### Port 3016 Already In Use

**Problem:** Installation fails with "port in use" error
**Solution:**
1. Check what's using port: `lsof -ti:3016`
2. If pdev-live-server already installed: Installer will offer upgrade
3. If another service: Change port in install.sh or stop other service

### SSH Connection Failed

**Problem:** "Cannot connect via SSH" error
**Solution:**
1. Verify SSH key: `ssh user@server exit` (should work without password)
2. Setup key: `ssh-copy-id user@server`
3. Test connection: `ssh -vvv user@server` (verbose mode for debugging)

### Database Not Ready

**Problem:** Server starts but crashes immediately
**Solution:**
1. Check PostgreSQL running: `systemctl status postgresql`
2. Test connection: `psql -h localhost -U postgres -c "SELECT 1"`
3. Check PM2 logs: `pm2 logs pdev-live-server`

---

## 🔄 Uninstalling

To completely remove PDev Live:

### Desktop App
```bash
# macOS
rm -rf "/Applications/PDev Live.app"
rm -rf "$HOME/Library/Application Support/PDev Live"

# Linux
sudo dpkg -r pdev-live
rm -rf ~/.config/pdev-live
```

### Server
```bash
# On server:
pm2 delete pdev-live-server
pm2 save
sudo rm -rf /opt/services/pdev-live

# Optional: Remove database
sudo -u postgres dropdb pdev_live
sudo -u postgres dropuser pdev_app
```

---

## 📞 Support

**Documentation:** See `docs/` directory in this bundle
**Logs:** Check `/tmp/pdev-installer-*.log` for installation logs
**Server Logs:** `pm2 logs pdev-live-server`
**Issues:** Report at GitHub repository

---

## 🔒 Security Notes

- Desktop app config file permissions: `600` (owner read/write only)
- Server `.env` file permissions: `600` (owner read/write only)
- SSH key authentication required for remote servers (no passwords)
- Database credentials stored in server `.env` file (never transmitted)
- Desktop app connects to server via HTTP (configure HTTPS separately)

---

## 📝 What Gets Modified

### On Your Computer
- **Installs:** PDev Live.app to `/Applications/` (macOS) or system location (Linux)
- **Creates:** Config file at `~/Library/Application Support/PDev Live/config.json`
- **Downloads:** Temporary installer files to `/tmp/` (removed after install)

### On Target Server
- **Creates:** `/opt/services/pdev-live/` directory
- **Installs:** Node.js dependencies via npm
- **Creates:** PostgreSQL database `pdev_live` with user `pdev_app`
- **Registers:** PM2 process `pdev-live-server`
- **Opens:** Port 3016 for API access

**Nothing else is modified.** No system files changed, no PATH modifications.

---

## 🎉 Next Steps After Installation

1. **Launch Desktop App** - Open from Applications
2. **Start Using PDev Suite** - Run `/pdev` commands in Claude sessions
3. **Share with Clients** - Generate guest links via desktop app
4. **Configure HTTPS** - For production, setup nginx reverse proxy (optional)
5. **Backup Database** - Setup automated backups: `pg_dump pdev_live`

---

**Installation support:** Check logs and troubleshooting docs first
**Enjoy using PDev Live!**
