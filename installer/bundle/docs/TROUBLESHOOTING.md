# PDev Live Installation - Troubleshooting Guide

This guide covers common installation issues and solutions for PDev Live desktop electron app and server.

---

## 🔍 Installation Failure Diagnosis

### Step 1: Locate Log File

Installation logs show:
```
[ERROR] Installation failed with exit code 1
Log file: /tmp/pdev-installer-1234567890.log
```

**View logs:**
```bash
cat /tmp/pdev-installer-*.log
tail -50 /tmp/pdev-installer-*.log
```

### Step 2: Identify Phase

Installation phases:
```
━━━ Phase 1: Pre-Flight Validation ━━━
━━━ Phase 2: Server Target Selection ━━━
━━━ Phase 3: Database Prerequisites ━━━
━━━ Phase 4: Server Installation ━━━
━━━ Phase 5: Desktop App Installation ━━━
━━━ Phase 6: Configuration ━━━
━━━ Phase 7: Final Verification ━━━
```

---

## 🐛 Common Issues by Phase

### Phase 1: Pre-Flight Validation

**Missing curl command:**
```bash
# macOS: brew install curl
# Ubuntu: sudo apt install curl
# CentOS: sudo yum install curl
```

**Missing SSH client:**
```bash
# Ubuntu: sudo apt install openssh-client
# CentOS: sudo yum install openssh-clients
```

**Insufficient disk space:**
```bash
df -h /tmp
sudo rm -rf /tmp/pdev-* /tmp/*.log
```

---

### Phase 2: Server Target Selection

**SSH connection failed:**
```bash
# Generate SSH key
ssh-keygen -t ed25519

# Copy to server
ssh-copy-id user@server.com

# Test
ssh user@server.com exit
```

**Port 3016 already in use:**
```bash
# Find process
lsof -ti:3016
ps aux | grep $(lsof -ti:3016)

# If PDev: installer offers upgrade
# If other: stop service or use different port
```

---

### Phase 3: Database Prerequisites

**PostgreSQL not installed:**
```bash
# Ubuntu: sudo apt install postgresql postgresql-contrib
# CentOS: sudo yum install postgresql-server
# macOS: brew install postgresql@14
```

**PostgreSQL not running:**
```bash
sudo systemctl start postgresql
sudo systemctl enable postgresql
```

**Connection failed:**
```bash
# Check config
sudo nano /etc/postgresql/*/main/pg_hba.conf

# Test
sudo -u postgres psql -c "SELECT 1"
```

---

### Phase 4: Server Installation

**Node.js not found:**
```bash
# Ubuntu: curl -fsSL https://deb.nodesource.com/setup_18.x | sudo -E bash -
# sudo apt-get install -y nodejs

# Verify: node --version
```

**PM2 not found:**
```bash
sudo npm install -g pm2
pm2 --version
```

**PM2 process not online:**
```bash
pm2 logs pdev-live-server --lines 100

# Check: database connection, port availability, dependencies
```

---

### Phase 5: Desktop App Installation

**Download failed:**
```bash
# Test manually
curl -I https://walletsnack.com/pdev/releases/PDev-Live-1.0.0.dmg

# Check internet connection
# Verify DNS resolution
```

**Checksum failed:**
```bash
# Re-download (don't skip verification)
rm /tmp/pdev-desktop.*
# Re-run installer
```

**macOS hdiutil missing:**
```bash
uname -s  # Verify macOS
xcode-select --install  # Reinstall tools
```

**Linux dpkg error:**
```bash
sudo apt --fix-broken install
sudo dpkg -r pdev-live
sudo dpkg -i /tmp/pdev-desktop.deb
```

---

### Phase 6: Configuration

**Cannot create config directory:**
```bash
# macOS
mkdir -p "$HOME/Library/Application Support/PDev Live"
chmod 755 "$HOME/Library/Application Support/PDev Live"

# Linux
mkdir -p "$HOME/.config/pdev-live"
chmod 755 "$HOME/.config/pdev-live"
```

---

### Phase 7: Final Verification

**Health check failed:**
```bash
# Test manually
curl -v http://localhost:3016/health

# Check PM2
pm2 logs pdev-live-server
lsof -ti:3016

# Check firewall
sudo ufw status
```

---

## 🪟 Windows/WSL Issues

**wdress server access:**
```bash
# Correct syntax for WSL
ssh wdress 'wsl -e bash -c "command"'

# The installer handles this automatically
```

**SSH keys on Windows:**
```
Location: C:\ProgramData\ssh\administrators_authorized_keys

Add key (Administrator cmd):
echo KEY >> C:\ProgramData\ssh\administrators_authorized_keys
```

---

## 🔄 Rollback Procedures

**Automatic rollback:**
```
Installation failed
Rollback installation? (y/n): y
```

**Manual rollback desktop:**
```bash
# macOS
rm -rf "/Applications/PDev Live.app"
rm -rf "$HOME/Library/Application Support/PDev Live"

# Linux
sudo dpkg -r pdev-live
rm -rf ~/.config/pdev-live
```

**Manual rollback server:**
```bash
pm2 delete pdev-live-server
pm2 save
sudo rm -rf /opt/services/pdev-live

# Optional: database
sudo -u postgres dropdb pdev_live
sudo -u postgres dropuser pdev_app
```

---

## 🧪 Test Components Individually

**Desktop app only:**
```bash
curl -L https://walletsnack.com/pdev/releases/PDev-Live-1.0.0.dmg -o ~/Downloads/pdev.dmg
open ~/Downloads/pdev.dmg

# Create config
mkdir -p "$HOME/Library/Application Support/PDev Live"
echo '{"serverUrl":"http://localhost:3016"}' > "$HOME/Library/Application Support/PDev Live/config.json"
```

**Server only:**
```bash
cd installer
./install.sh
curl http://localhost:3016/health
```

---

## 📊 Diagnostic Commands

**System:**
```bash
uname -a
df -h
free -h  # Linux
vm_stat # macOS
```

**Process:**
```bash
pm2 list
pm2 jlist
lsof -ti:3016
netstat -tuln | grep 3016
```

**Database:**
```bash
sudo systemctl status postgresql
sudo -u postgres psql -c "\l"
sudo -u postgres psql pdev_live -c "SELECT 1"
```

---

## 🚨 Emergency Recovery

**Server completely broken:**
```bash
pm2 kill
sudo rm -rf /opt/services/pdev-live
sudo -u postgres dropdb pdev_live
sudo -u postgres dropuser pdev_app

# Re-run installer
```

**Desktop app corrupted:**
```bash
rm -rf "/Applications/PDev Live.app"
rm -rf "$HOME/Library/Application Support/PDev Live"

# Re-download and install manually
```

---

## 📞 Getting Help

**Collect diagnostics:**
```bash
{
  echo "=== System ==="
  uname -a
  node --version
  pm2 --version

  echo "=== PM2 ==="
  pm2 list
  pm2 logs pdev-live-server --lines 100 --nostream

  echo "=== Install Log ==="
  cat /tmp/pdev-installer-*.log
} > ~/pdev-diagnostic.txt
```

**Report with:**
- OS and version
- Installation mode
- Failed phase
- Error message
- Diagnostic file

---

Good luck! 🚀
