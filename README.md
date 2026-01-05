# PDev Live

Real-time session streaming system for PDev Suite. Stream Claude development sessions to clients via web interface with live updates, document sync, and guest sharing.

## Architecture

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│     Client      │────▶│   PDev API      │────▶│    Frontend     │
│   (CLI/Hooks)   │     │   (port 3016)   │     │   (HTML/JS)     │
└─────────────────┘     └─────────────────┘     └─────────────────┘
        │                       │                        │
        │               ┌───────┴───────┐                │
        │               │               │                │
        ▼               ▼               ▼                ▼
┌─────────────┐   ┌───────────┐   ┌───────────┐   ┌───────────┐
│ PDev Live   │   │ PostgreSQL│   │   SSE     │   │  Guest    │
│  (Stream)   │   │  Storage  │   │  Events   │   │  Links    │
└─────────────┘   └───────────┘   └───────────┘   └───────────┘
```

## CSS Architecture

PDev Live uses a multi-file CSS structure for optimal caching and maintainability:

### External Dependencies
All pages load syntax highlighting CSS first:
- **highlight.js** (github-dark theme) - Code syntax highlighting for markdown rendering
- Loaded via CDN before local CSS to allow local overrides if needed

### Base CSS
- **pdev-live.css** (12KB) - Shared styles loaded by all pages
  - Navigation
  - Modals
  - Forms
  - Buttons
  - Global layout

### Page-Specific CSS
- **session-specific.css** (2.3KB) - Session viewer page
  - Session header
  - Phase navigation
  - Document items
- **project-specific.css** (5.8KB) - Project viewer page
  - Breadcrumb navigation
  - Project header
  - Meta-card (YAML rendering)

### Minimal Page-Specific CSS
Two pages have intentionally minimal page-specific CSS:

**index-specific.css (333B)**
- Dashboard page uses primarily shared components
- File exists for consistency but contains only comments
- Future dashboard-specific overrides would go here

**live.html (NO page-specific CSS)**
- Uses only generic shared components (container, sidebar, buttons, empty-state)
- No unique styling needs
- Most minimal page in the application

### Load Order
All pages load base CSS first, then page-specific CSS:
```html
<link rel="stylesheet" href="https://cdnjs.cloudflare.com/ajax/libs/highlight.js/11.9.0/styles/github-dark.min.css">
<link rel="stylesheet" href="pdev-live.css">
<link rel="stylesheet" href="page-specific.css"> <!-- if applicable -->
```

### Why This Architecture?
- **Cache Efficiency:** Base CSS cached once, used by all pages
- **Separation of Concerns:** Page-specific styles isolated
- **Performance:** Smaller page-specific files load faster
- **Maintainability:** Changes to one page don't affect others

### Quick Reference Table

| File | Size | Pages | Primary Purpose |
|------|------|-------|-----------------|
| pdev-live.css | 12KB | All | Navigation, modals, forms, buttons, layout |
| session-specific.css | 2.3KB | session.html | Session header, phase nav, document items |
| project-specific.css | 5.8KB | project.html | Breadcrumb, project header, meta-card (YAML) |
| index-specific.css | 333B | index.html | Dashboard overrides (currently minimal) |
| (none) | - | live.html | No page-specific CSS needed |

### Maintenance Guidelines

**When to add to pdev-live.css:**
- Component used by 2+ pages
- Navigation/modal/form styles
- Global utilities (.muted-text, .btn variants)

**When to add to page-specific.css:**
- Component unique to single page
- Page-specific layout overrides
- Specialized UI (meta-card, breadcrumb, phase nav)

**Before creating new CSS file:**
- Verify component isn't already in pdev-live.css
- Check if existing page-specific file should be used
- Consider if component could become shared later

## Components

### `/api` - PDev API Server (port 3016)
- Project and session management
- Document storage and retrieval
- Guest link creation and validation
- Serves `/pdev/api/*` endpoints

### `/server` - PDev Live Streaming Server
- Real-time SSE (Server-Sent Events) streaming
- Document sync from Claude sessions
- Webhook receivers for pipeline updates
- `doc-contract.json` - Canonical document type definitions

### `/client` - CLI Client
- `client.sh` - Shell script for pushing updates
- Installed to `~/.claude/tools/pdev-live/`
- Called by hooks and `/pdev-live` command

### `/frontend` - Web Interface
- `index.html` - Dashboard with active sessions
- `project.html` - Project view with pipeline documents
- `session.html` - Live session viewer with step navigation
- `mgmt.js` - Management functions (share links, etc.)

## Features

- **Live Streaming**: Watch Claude sessions in real-time via SSE
- **Document Sync**: Pipeline docs (IDEATION, SPEC, SOP, etc.) auto-sync
- **Share with Client**: Generate time-limited guest links (24h-1 week)
- **Guest View**: Clients see project docs without share capabilities
- **Multi-Server**: Works across all servers (ittz, acme, cfree, rmlve, djm, wdress)

## Installation

### API Server (on acme)
```bash
cd api
npm install
pm2 start pm2.config.js --name pdev-api
```

### Streaming Server (on acme)
```bash
cd server
npm install
pm2 start ecosystem.config.js --name pdev-live
```

### Client (all servers)
```bash
# Via /ct command (recommended)
/ct

# Or manually:
mkdir -p ~/.claude/tools/pdev-live
cp client/client.sh ~/.claude/tools/pdev-live/
chmod +x ~/.claude/tools/pdev-live/client.sh

# Configure PDev Live server URL
cat > ~/.pdev-live-config <<EOF
# PDev Live Client Configuration
PDEV_LIVE_URL=https://walletsnack.com/pdev/api
PDEV_BASE_URL=https://walletsnack.com/pdev
EOF
chmod 600 ~/.pdev-live-config
```

**Note**: The installer (`pdl-installer.sh`) automatically generates `~/.pdev-live-config` during installation.

### Frontend & Backend Deployment (acme server)

**Use the automated deployment script (recommended):**

```bash
cd ~/projects/pdev-live
./update.sh
```

**Deployment Phases:**
1. ✅ Backup current production files
2. ✅ Pull latest code from GitHub
3. ✅ Syntax validation (Node.js, JSON, CSS, HTML)
4. ✅ Deploy backend via scp
5. ✅ Deploy frontend via rsync (atomic)
6. ✅ Restart PM2 service
7. ✅ Deployment verification (PM2 status, file existence, HTTP)
8. ✅ Backup rotation (keep 10, delete >30 days)
9. ✅ Record deployment commit hash

**Rollback:** If deployment fails, update.sh automatically restores from backup.

**Post-Deployment Checklist:**
- [ ] Run: `/cache-bust https://walletsnack.com/pdev/live/`
- [ ] Test: https://walletsnack.com/pdev/live/ (Ctrl+Shift+R)
- [ ] Verify: F12 console has zero CSS 404 errors
- [ ] Check all pages: index.html, session.html, project.html, live.html

**Manual Deployment (not recommended):**
```bash
# Only if update.sh unavailable
rsync -avz --checksum frontend/ acme:/var/www/walletsnack.com/pdev/live/
scp server/server.js acme:/opt/services/pdev-live/server.js
ssh acme 'pm2 restart pdev-live'
```

**See:** [DEPLOYMENT.md](DEPLOYMENT.md) for full deployment documentation.

### Partner Self-Hosted Installation

The installer supports two modes:

**Source Server (Full Stack):** Hosts PDev-Live backend (database, nginx, PM2, API)
**Project Server (Client Only):** Posts data to a source server

**Prerequisites (Source Server):**
- Ubuntu 22.04 LTS server
- Domain name pointed to server IP
- Root/sudo access

**Source Server Installation:**
```bash
cd ~/projects/pdev-live/installer
sudo ./pdl-installer.sh --domain pdev.yourdomain.com
```

**Project Server Installation:**
```bash
cd ~/projects/pdev-live/installer
sudo ./pdl-installer.sh --source-url https://pdev.yourdomain.com/pdev/api
```

**What Gets Installed (Source Mode):**
- ✅ Node.js 20.x LTS
- ✅ PostgreSQL 15 with pdev_live database
- ✅ Nginx with Let's Encrypt SSL
- ✅ PM2 process manager
- ✅ UFW firewall (SSH, HTTP, HTTPS)
- ✅ Fail2Ban brute-force protection
- ✅ Express.js serving frontend HTML/CSS/JS
- ✅ HTTP Basic Auth (nginx + Express layers)
- ✅ PDev Live client CLI tool

**What Gets Installed (Project Mode):**
- ✅ PDev Live client CLI tool only (~/.claude/tools/pdev-live/client.sh)
- ✅ Config file pointing to source server (~/.pdev-live-config)

**Configuration (Source Mode):**
- Domain: Provided during installation
- Base URL: `https://your-domain.com`
- Static Serving: `PDEV_SERVE_STATIC=true`
- HTTP Auth: `PDEV_HTTP_AUTH=true` (defense-in-depth)

**Configuration (Project Mode):**
- Source URL: Points to your source server's API endpoint
- Client posts data to source server automatically

**Post-Install:**
```bash
# View logs
pm2 logs pdev-live

# Run security audit
sudo ./security-audit.sh

# Access dashboard
https://your-domain.com
```

**Key Differences from Walletsnack:**
| Feature | Walletsnack | Partner |
|---------|-------------|---------|
| Frontend Serving | Nginx | Express.js |
| Desktop App | Yes | No (web-only) |
| Static Files | `/var/www/` | `/opt/pdev-live/frontend/` |
| HTTP Auth | Nginx only | Nginx + Express |
| Base URL | `walletsnack.com/pdev/live/` | `https://partner-domain.com` |

**See:** [Partner Installation Guide](installer/README-PARTNER.md) for detailed setup.

## Usage

### Start a session
```bash
~/.claude/tools/pdev-live/client.sh start <project> [command]
# Example: client.sh start seefree /spec
```

### Push a step
```bash
~/.claude/tools/pdev-live/client.sh step "output" "Content here"
```

### Push a document
```bash
~/.claude/tools/pdev-live/client.sh doc "IDEATION" /path/to/IDEATION.md
```

### Create a guest link
```bash
~/.claude/tools/pdev-live/client.sh share [hours] [email]
# Example: client.sh share 48 client@example.com
```

### End a session
```bash
~/.claude/tools/pdev-live/client.sh end
```

## API Endpoints

### Sessions
- `POST /sessions` - Create session
- `GET /sessions/:id` - Get session with steps
- `POST /sessions/:id/steps` - Add step
- `POST /sessions/:id/complete` - End session

### Projects
- `GET /projects/:server/:project/docs` - Get project documents
- `GET /projects/:server/:project/sessions` - Get project sessions

### Events
- `GET /events/:id` - SSE stream for live updates

### Guest Links
- `POST /guest-links` - Create guest link
- `GET /guest/:token` - Validate guest token

## Document Types

Defined in `server/doc-contract.json`:
- IDEATION, BENCHMARK, GAP_ANALYSIS, INNOVATION
- CAPABILITIES, PRODUCT_SPEC, DESIGN_SYSTEM
- DEVELOPMENT_SOP, EVALUATION

## Environment

| Component | Location | Port |
|-----------|----------|------|
| PDev API | acme:/home/acme/pdev-api | 3016 |
| PDev Live | acme:/opt/services/pdev-live | internal |
| Frontend | walletsnack.com/pdev/live/ | 443 |
| API URL | walletsnack.com/pdev/api/ | 443 |

## PM2 Commands

```bash
# View logs
pm2 logs pdev-api
pm2 logs pdev-live

# Restart
pm2 restart pdev-api
pm2 restart pdev-live

# Status
pm2 status
```
