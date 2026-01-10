# PDev-Live Installer Documentation

**Version:** 1.0.17
**Last Updated:** 2026-01-10
**Compliance Score:** 10/10 ✅

---

## Table of Contents

1. [Architecture Overview](#architecture-overview)
2. [Installation Modes](#installation-modes)
3. [Security Flow](#security-flow)
4. [Rollback Decision Tree](#rollback-decision-tree)
5. [Troubleshooting Flowchart](#troubleshooting-flowchart)
6. [Prerequisites](#prerequisites)
7. [Usage Examples](#usage-examples)
8. [Validation & Testing](#validation--testing)

---

## Architecture Overview

### System Architecture Diagram

```
┌─────────────────────────────────────────────────────────────────────┐
│                         PDev-Live Architecture                       │
├─────────────────────────────────────────────────────────────────────┤
│                                                                       │
│  ┌─────────────────┐                    ┌─────────────────┐        │
│  │  Source Server  │                    │ Project Server  │        │
│  │   (Full Stack)  │                    │ (Client Only)   │        │
│  ├─────────────────┤                    ├─────────────────┤        │
│  │                 │                    │                 │        │
│  │  ┌───────────┐  │                    │  ┌───────────┐  │        │
│  │  │  Nginx    │◄─┼────────────────────┼──┤  CLI      │  │        │
│  │  │  (HTTPS)  │  │  POST /sessions    │  │  Client   │  │        │
│  │  └─────┬─────┘  │                    │  └───────────┘  │        │
│  │        │        │                    │                 │        │
│  │  ┌─────▼─────┐  │                    │  Uses:          │        │
│  │  │  Node.js  │  │                    │  - curl         │        │
│  │  │  Express  │  │                    │  - jq           │        │
│  │  │  (PM2)    │  │                    │  - bash         │        │
│  │  └─────┬─────┘  │                    │                 │        │
│  │        │        │                    └─────────────────┘        │
│  │  ┌─────▼─────┐  │                                               │
│  │  │PostgreSQL │  │                                               │
│  │  │ pdev_live │  │                                               │
│  │  └───────────┘  │                                               │
│  │                 │                                               │
│  └─────────────────┘                                               │
│                                                                     │
└─────────────────────────────────────────────────────────────────────┘
```

### Data Flow

```
Claude Code (/idea, /spec, etc.)
    │
    ├─► Source Server Mode:
    │   └─► Local PostgreSQL → Local PM2 → Local Browser
    │
    └─► Project Server Mode:
        └─► HTTPS POST → Source Server API → PostgreSQL
            └─► SSE → Browser on Source Server
```

---

## Installation Modes

### Mode Comparison

| Feature | Source Server | Project Server |
|---------|--------------|----------------|
| **Purpose** | Hosts PDev-Live backend | Streams to remote source |
| **Components** | PostgreSQL, nginx, PM2, Node.js | CLI client only |
| **Requirements** | Full stack (2GB disk, 1GB RAM) | Minimal (bash, curl, jq) |
| **Network** | Domain name + SSL | Outbound HTTPS to source |
| **Use Case** | Central PDev-Live instance | Multiple project servers |
| **Complexity** | High | Low |

### Mode Selection Decision Tree

```
┌─────────────────────────────────────────┐
│  What are you trying to accomplish?     │
└───────────────┬─────────────────────────┘
                │
        ┌───────┴────────┐
        │                │
    ┌───▼───┐      ┌────▼────┐
    │ Host  │      │ Connect │
    │PDev-  │      │   to    │
    │Live?  │      │existing?│
    └───┬───┘      └────┬────┘
        │               │
    ┌───▼───────────────▼───┐
    │ SOURCE MODE       │PROJECT MODE
    │                   │
    │ Install:          │ Install:
    │ - PostgreSQL      │ - CLI client
    │ - nginx           │ - .env config
    │ - PM2             │
    │ - Node.js app     │ Points to:
    │ - SSL cert        │ - Source URL
    │                   │
    │ Provides:         │ Provides:
    │ - Web UI          │ - /idea, /spec
    │ - API endpoints   │   commands
    │ - Database        │
    └───────────────────┴───────────────
```

---

## Security Flow

### Credential Generation → Storage → Usage

```
┌─────────────────────────────────────────────────────────────────────┐
│                    Security Flow Diagram                             │
├─────────────────────────────────────────────────────────────────────┤
│                                                                       │
│  Phase 1: GENERATION (openssl rand)                                 │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                                                               │   │
│  │  DB Password:      openssl rand -base64 32  (256 bits)       │   │
│  │  Admin API Key:    openssl rand -base64 48  (384 bits)       │   │
│  │  HTTP Password:    openssl rand -base64 24  (192 bits)       │   │
│  │  Session Secret:   openssl rand -hex 32     (256 bits)       │   │
│  │                                                               │   │
│  │  Character Filter: tr -d '/+='  (SQL injection prevention)   │   │
│  │                                                               │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                              │                                       │
│                              ▼                                       │
│  Phase 2: STORAGE (600 permissions, owner-only)                     │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                                                               │   │
│  │  /opt/pdev-live/.env                     (600, root:root)    │   │
│  │  /etc/nginx/.htpasswd                    (600, root:root)    │   │
│  │  ~/.pdev-live-config                     (600, user:user)    │   │
│  │                                                               │   │
│  │  Log Bypass: Credentials → /dev/tty (NOT logged to file)     │   │
│  │                                                               │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                              │                                       │
│                              ▼                                       │
│  Phase 3: USAGE (runtime)                                           │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                                                               │   │
│  │  PostgreSQL:  env DB_PASSWORD via connection string          │   │
│  │  nginx:       HTTP Basic Auth via .htpasswd                  │   │
│  │  Express:     env SESSION_SECRET for cookie signing          │   │
│  │  API:         env ADMIN_KEY for /pdev/installer/* endpoints  │   │
│  │                                                               │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                              │                                       │
│                              ▼                                       │
│  Phase 4: SECURE DELETION (rollback)                                │
│  ┌─────────────────────────────────────────────────────────────┐   │
│  │                                                               │   │
│  │  shred -vfz -n 3 .env        (3-pass overwrite)              │   │
│  │  shred -vfz -n 3 .htpasswd   (3-pass overwrite)              │   │
│  │  Fallback: dd if=/dev/urandom (random overwrite)             │   │
│  │                                                               │   │
│  └─────────────────────────────────────────────────────────────┘   │
│                                                                       │
└─────────────────────────────────────────────────────────────────────┘
```

---

## Rollback Decision Tree

### Installation Failure → Cleanup Flow

```
┌──────────────────────────────────────────┐
│   Installation Failed (exit code ≠ 0)   │
└────────────────┬─────────────────────────┘
                 │
         ┌───────▼────────┐
         │  DRY_RUN?      │
         └───┬────────┬───┘
             │        │
          YES│        │NO
             │        │
    ┌────────▼──┐  ┌─▼────────────────────┐
    │  Skip     │  │  Check INTERACTIVE   │
    │  Rollback │  └─┬────────────────┬───┘
    └───────────┘    │                │
                  YES│                │NO
                     │                │
         ┌───────────▼──┐    ┌────────▼────────────┐
         │ Prompt User  │    │  Automatic Rollback │
         │ (y/n)?       │    │  (Non-interactive)  │
         └───┬──────┬───┘    └──────────┬──────────┘
             │      │                   │
          y  │      │ n                 │
             │      │                   │
    ┌────────▼──────▼───────────────────▼────────┐
    │                                             │
    │          ROLLBACK SEQUENCE                  │
    │                                             │
    │  1. Stop PM2 process (if PM2_STARTED)      │
    │     └─► pm2 delete pdev-live               │
    │                                             │
    │  2. Secure delete .env (if exists)         │
    │     └─► shred -vfz -n 3 .env               │
    │                                             │
    │  3. Secure delete .htpasswd (if exists)    │
    │     └─► shred -vfz -n 3 .htpasswd          │
    │                                             │
    │  4. Drop database (if DB_CREATED)          │
    │     ├─► Interactive: Prompt y/n            │
    │     └─► Non-interactive: Auto-drop         │
    │                                             │
    │  5. Remove nginx config (if NGINX_CONFIG)  │
    │     └─► rm -f /etc/nginx/sites-*/pdev-live │
    │                                             │
    │  6. Remove install directory (if FILES_*)  │
    │     └─► rm -rf /opt/pdev-live              │
    │                                             │
    │  7. Reload nginx (if config removed)       │
    │     └─► nginx -s reload                    │
    │                                             │
    └─────────────────────────────────────────────┘
                         │
                         ▼
                ┌────────────────┐
                │  Exit (code 1) │
                └────────────────┘
```

---

## Troubleshooting Flowchart

### Common Installation Issues

```
┌─────────────────────────────────────────────────────────────────┐
│                  Installation Failed?                            │
└─────────────────────────┬───────────────────────────────────────┘
                          │
              ┌───────────▼──────────┐
              │  Error Type?         │
              └─┬─────┬─────┬────┬───┘
                │     │     │    │
     ┌──────────┘     │     │    └──────────┐
     │                │     │               │
┌────▼─────┐  ┌──────▼──┐ ┌▼────────┐ ┌────▼─────┐
│PM2 Error │  │DB Error │ │Network  │ │Permission│
└────┬─────┘  └────┬────┘ │Error    │ │Error     │
     │             │       └┬────────┘ └┬─────────┘
     │             │        │           │
     │  ┌──────────▼────────▼───────────▼─────┐
     │  │                                      │
     │  │  PM2 ERRORS                          │
     │  │  ─────────────────────────────────   │
     │  │  Error: Process not found            │
     │  │  Fix: Installed v1.0.16+             │
     │  │       (uses pm2 show detection)      │
     │  │                                      │
     │  │  Error: Port 3016 in use             │
     │  │  Fix: lsof -ti:3016 | xargs kill     │
     │  │       OR: --force flag               │
     │  │                                      │
     │  │  DB ERRORS                            │
     │  │  ─────────────────────────────────   │
     │  │  Error: role "pdev_app" exists       │
     │  │  Fix: sudo -u postgres psql          │
     │  │       DROP USER pdev_app;            │
     │  │                                      │
     │  │  Error: database "pdev_live" exists  │
     │  │  Fix: Use --force flag               │
     │  │       OR: Manual drop                │
     │  │                                      │
     │  │  NETWORK ERRORS                       │
     │  │  ─────────────────────────────────   │
     │  │  Error: Cannot resolve vyxenai.com   │
     │  │  Fix: Check DNS (cat /etc/resolv.conf)│
     │  │       Test: nslookup vyxenai.com     │
     │  │                                      │
     │  │  Error: Connection refused            │
     │  │  Fix: Check firewall (ufw status)    │
     │  │       Check internet (ping 8.8.8.8)  │
     │  │                                      │
     │  │  PERMISSION ERRORS                    │
     │  │  ─────────────────────────────────   │
     │  │  Error: Permission denied             │
     │  │  Fix: Run with sudo                  │
     │  │                                      │
     │  │  Error: Cannot write to /opt          │
     │  │  Fix: sudo chown root:root /opt      │
     │  │       sudo chmod 755 /opt            │
     │  │                                      │
     │  └──────────────────────────────────────┘
     │
     └─────► Check Log File: /tmp/pdl-installer-*.log
```

---

## Prerequisites

### System Requirements

**Source Server Mode:**
- OS: Ubuntu 20.04+ or Debian 11+
- Node.js: ≥18.x
- PostgreSQL: ≥14.x
- nginx: ≥1.18
- Disk Space: ≥2GB free
- RAM: ≥1GB
- Domain: Valid DNS A record
- SSL: Let's Encrypt or custom certificate

**Project Server Mode:**
- OS: Any Linux with bash
- Tools: curl, jq, bash
- Network: Outbound HTTPS to source server
- Disk Space: ≥100MB

### Network Requirements

- **Source Server:**
  - Inbound: Port 443 (HTTPS)
  - Outbound: Port 443 (package downloads)

- **Project Server:**
  - Outbound: Port 443 (API communication to source)

---

## Usage Examples

### Interactive Source Server Installation

```bash
# Download and run installer
curl -fsSL https://vyxenai.com/pdev/install.sh | sudo bash

# Select mode: 1 (Source Server)
# Enter domain: pdev.example.com
# Credentials auto-generated and displayed
```

### Non-Interactive Source Server Installation

```bash
curl -fsSL https://vyxenai.com/pdev/install.sh | \
  sudo bash -s -- --domain pdev.example.com --non-interactive
```

### Force Overwrite Existing Installation

```bash
sudo ./pdl-installer.sh \
  --domain pdev.example.com \
  --force \
  --non-interactive
```

### Dry-Run (Preview Without Changes)

```bash
sudo ./pdl-installer.sh \
  --domain pdev.example.com \
  --dry-run
```

### Custom Installation Directory

```bash
sudo ./pdl-installer.sh \
  --domain pdev.example.com \
  --install-dir /home/pdev/app
```

### Project Server Installation

```bash
curl -fsSL https://vyxenai.com/pdev/install.sh | \
  sudo bash -s -- --source-url https://pdev.example.com/pdev/api
```

---

## Validation & Testing

### Post-Install Verification Checklist

```bash
# 1. PM2 Process Status
pm2 status
# Expected: pdev-live-server status = online

# 2. Database Connectivity
sudo -u postgres psql -d pdev_live -c 'SELECT COUNT(*) FROM pdev_sessions;'
# Expected: Numeric result (may be 0)

# 3. HTTP Health Check
curl -u admin:*** http://localhost:3016/health
# Expected: {"status":"healthy"}

# 4. HTTPS Endpoint
curl -u admin:*** https://pdev.example.com/health
# Expected: {"status":"healthy"}

# 5. Nginx Configuration
nginx -t
# Expected: test is successful

# 6. File Permissions
stat -c '%a %n' /opt/pdev-live/.env /etc/nginx/.htpasswd
# Expected: 600 for both files

# 7. SSL Certificate
openssl s_client -connect pdev.example.com:443 -servername pdev.example.com < /dev/null
# Expected: Verify return code: 0 (ok)
```

### Idempotency Test

```bash
# Run installer twice on same system
sudo ./pdl-installer.sh --domain pdev.example.com --dry-run
sudo ./pdl-installer.sh --domain pdev.example.com --dry-run
# Expected: Second run detects existing installation, prompts or skips
```

### Rollback Test

```bash
# Trigger installation failure mid-execution
sudo ./pdl-installer.sh --domain pdev.example.com &
sleep 30 && kill -9 $!
# Expected: Automatic rollback triggered, credentials deleted
```

### Security Validation

```bash
# Verify credentials NOT in log file
grep -i "password\|secret\|key" /tmp/pdl-installer-*.log
# Expected: No matches (credentials bypass log via /dev/tty)

# Verify file permissions
find /opt/pdev-live -name ".env" -exec stat -c '%a %n' {} \;
# Expected: 600 /opt/pdev-live/.env
```

---

## Support & Documentation

- **Runbook:** `~/claude-tools/runbooks/RUNBOOK_PDEV-LIVE_20260101.md`
- **Agent Matrix:** `~/.claude/AGENT_MATRIX.md`
- **Pipeline Docs:** `~/.claude/PDEV_PIPELINE.md`
- **GitHub Issues:** https://github.com/dolovegitlove/pdev-live/issues

---

## Version History

- **v1.0.17** - Documentation completeness (architecture diagrams, troubleshooting)
- **v1.0.16** - Compliance fixes (PM2 detection, auto-rollback, credential logging)
- **v1.0.15** - Initial production release
- **v1.0.13** - Beta testing
