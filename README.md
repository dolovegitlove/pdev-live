# PDev Live

Real-time session streaming system for PDev Suite. Allows clients to watch Claude development sessions live via web interface.

## Architecture

```
┌─────────────┐     ┌─────────────┐     ┌─────────────┐
│   Client    │────▶│   API       │────▶│  Frontend   │
│  (CLI/Hook) │     │  (Express)  │     │  (HTML/JS)  │
└─────────────┘     └─────────────┘     └─────────────┘
                          │
                          ▼
                    ┌─────────────┐
                    │  PostgreSQL │
                    └─────────────┘
```

## Components

### `/client`
- `client.sh` - CLI tool for pushing steps to PDev Live sessions
- Installed to `~/.claude/tools/pdev-live/`
- Called by hooks and pipeline commands

### `/api`
- `server.js` - Express API server
- Handles sessions, steps, SSE events, guest links
- PostgreSQL storage

### `/frontend`
- `index.html` - PDev Suite landing page
- `dashboard.html` - Live sessions dashboard
- `session.html` - Individual session viewer
- `mgmt.js` - Management functions

## Installation

### API Server (on acme)
```bash
cd api
npm install
pm2 start pm2.config.js
```

### Client (all servers)
```bash
mkdir -p ~/.claude/tools/pdev-live
cp client/client.sh ~/.claude/tools/pdev-live/
chmod +x ~/.claude/tools/pdev-live/client.sh
```

### Frontend (nginx)
```bash
cp frontend/* /var/www/walletsnack.com/pdev/live/
```

## Usage

### Start a session
```bash
~/.claude/tools/pdev-live/client.sh start <project> [command]
```

### Push a step
```bash
~/.claude/tools/pdev-live/client.sh step "output" "Content here"
```

### Push a document
```bash
~/.claude/tools/pdev-live/client.sh doc "IDEATION.md" /path/to/file
```

### End a session
```bash
~/.claude/tools/pdev-live/client.sh end
```

## API Endpoints

- `POST /api/sessions` - Create session
- `GET /api/sessions/:id` - Get session with steps
- `POST /api/sessions/:id/steps` - Add step
- `GET /api/events/:id` - SSE stream
- `POST /api/sessions/:id/complete` - End session
- `GET /api/guest/:token` - Validate guest link

## Environment

API runs on acme server at `https://walletsnack.com/pdev/api/`

Frontend at `https://walletsnack.com/pdev/live/`
