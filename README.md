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
```

### Frontend (nginx on acme)
```bash
cp frontend/* /var/www/walletsnack.com/pdev/live/
```

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
