#!/usr/bin/env bash
#
# PDev Live Self-Hosted Installer
# Version: 1.0.0
#
# Usage: ./install.sh [OPTIONS]
#
# Options:
#   --non-interactive    Run without prompts (uses defaults)
#   --yes               Auto-accept all prompts
#   --install-dir PATH  Custom installation directory (default: /opt/services/pdev-live)
#   --port PORT         Custom port (default: 3016)
#   --help              Show this help message
#

set -euo pipefail
IFS=$'\n\t'

# =============================================================================
# CONFIGURATION
# =============================================================================
VERSION="1.0.0"
DEFAULT_INSTALL_DIR="/opt/services/pdev-live"
DEFAULT_PORT="3016"
DEFAULT_DB_NAME="pdev_live"
DEFAULT_DB_USER="pdev_app"

# Runtime configuration (can be overridden by arguments)
INSTALL_DIR="${INSTALL_DIR:-$DEFAULT_INSTALL_DIR}"
PORT="${PORT:-$DEFAULT_PORT}"
DB_NAME="${DB_NAME:-$DEFAULT_DB_NAME}"
DB_USER="${DB_USER:-$DEFAULT_DB_USER}"
INTERACTIVE="${INTERACTIVE:-true}"
DEFAULT_YES="${DEFAULT_YES:-false}"

# State tracking for cleanup
TEMP_FILES=()
CLEANUP_DONE=false

# =============================================================================
# COLOR CODES (with terminal check)
# =============================================================================
if [[ -t 1 ]]; then
    RED='\033[0;31m'
    GREEN='\033[0;32m'
    YELLOW='\033[1;33m'
    BLUE='\033[0;34m'
    BOLD='\033[1m'
    NC='\033[0m'
else
    RED='' GREEN='' YELLOW='' BLUE='' BOLD='' NC=''
fi

# =============================================================================
# LOGGING FUNCTIONS
# =============================================================================
log()   { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
header() { echo -e "\n${BOLD}${BLUE}=== $* ===${NC}\n"; }

# =============================================================================
# CLEANUP TRAP
# =============================================================================
cleanup() {
    [[ "$CLEANUP_DONE" == "true" ]] && return
    CLEANUP_DONE=true

    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        error "Installation failed with exit code $exit_code"

        for file in "${TEMP_FILES[@]:-}"; do
            [[ -f "$file" ]] && rm -f "$file"
        done

        error "Check the logs above for details."
    fi
}

trap cleanup EXIT ERR INT TERM

# =============================================================================
# HELP
# =============================================================================
show_help() {
    cat << EOF
PDev Live Self-Hosted Installer v${VERSION}

Usage: ./install.sh [OPTIONS]

Options:
  --non-interactive    Run without prompts (uses defaults)
  --yes, -y           Auto-accept all prompts
  --install-dir PATH  Custom installation directory (default: $DEFAULT_INSTALL_DIR)
  --port PORT         Custom port (default: $DEFAULT_PORT)
  --help, -h          Show this help message

Examples:
  ./install.sh                          # Interactive installation
  ./install.sh --yes                    # Accept all defaults
  ./install.sh --install-dir /opt/pdev  # Custom directory

Environment Variables:
  INSTALL_DIR    Installation directory
  PORT           Server port
  DB_NAME        PostgreSQL database name
  DB_USER        PostgreSQL user name
EOF
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================
parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --non-interactive)
                INTERACTIVE=false
                shift
                ;;
            --yes|-y)
                DEFAULT_YES=true
                shift
                ;;
            --install-dir)
                INSTALL_DIR="$2"
                shift 2
                ;;
            --port)
                PORT="$2"
                shift 2
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                error "Unknown option: $1"
                show_help
                exit 1
                ;;
        esac
    done
}

# =============================================================================
# OS DETECTION
# =============================================================================
detect_os() {
    OS=""
    PKG_MANAGER=""
    PKG_UPDATE=""
    PKG_INSTALL=""

    if [[ -f /etc/debian_version ]]; then
        OS="debian"
        if command -v apt &>/dev/null; then
            PKG_MANAGER="apt"
            PKG_UPDATE="apt update"
            PKG_INSTALL="apt install -y"
        else
            PKG_MANAGER="apt-get"
            PKG_UPDATE="apt-get update"
            PKG_INSTALL="apt-get install -y"
        fi
    elif [[ -f /etc/redhat-release ]]; then
        OS="rhel"
        if command -v dnf &>/dev/null; then
            PKG_MANAGER="dnf"
            PKG_INSTALL="dnf install -y"
        else
            PKG_MANAGER="yum"
            PKG_INSTALL="yum install -y"
        fi
        PKG_UPDATE="${PKG_MANAGER} check-update || true"
    elif [[ "$OSTYPE" == "darwin"* ]]; then
        OS="macos"
        PKG_MANAGER="brew"
        PKG_UPDATE="brew update"
        PKG_INSTALL="brew install"
    else
        error "Unsupported operating system."
        error "Supported: Debian/Ubuntu, RHEL/CentOS/Fedora, macOS"
        exit 1
    fi

    log "Detected OS: $OS (Package Manager: $PKG_MANAGER)"
}

# =============================================================================
# USER PROMPTS
# =============================================================================
prompt_user() {
    local prompt="$1"
    local default="${2:-N}"
    local timeout="${3:-60}"
    local response

    if [[ "$INTERACTIVE" != "true" ]]; then
        if [[ "$DEFAULT_YES" == "true" ]]; then
            return 0
        else
            return 1
        fi
    fi

    local prompt_text="$prompt [y/N]: "
    if [[ "$default" == "Y" ]]; then
        prompt_text="$prompt [Y/n]: "
    fi

    if read -r -t "$timeout" -p "$prompt_text" response; then
        case "$response" in
            [Yy]|[Yy][Ee][Ss]) return 0 ;;
            [Nn]|[Nn][Oo]) return 1 ;;
            "")
                [[ "$default" == "Y" ]] && return 0 || return 1
                ;;
            *)
                [[ "$default" == "Y" ]] && return 0 || return 1
                ;;
        esac
    else
        warn "Prompt timed out. Using default: $default"
        [[ "$default" == "Y" ]] && return 0 || return 1
    fi
}

# =============================================================================
# SECURE PASSWORD GENERATION
# =============================================================================
generate_secure_password() {
    local length="${1:-32}"
    local password=""

    # Method 1: OpenSSL (preferred)
    if command -v openssl &>/dev/null; then
        password=$(openssl rand -base64 48 2>/dev/null | tr -dc 'a-zA-Z0-9' | head -c "$length")
    fi

    # Method 2: /dev/urandom fallback
    if [[ -z "$password" ]] && [[ -r /dev/urandom ]]; then
        password=$(tr -dc 'a-zA-Z0-9' </dev/urandom 2>/dev/null | head -c "$length")
    fi

    # Method 3: Python fallback
    if [[ -z "$password" ]] && command -v python3 &>/dev/null; then
        password=$(python3 -c "import secrets, string; print(''.join(secrets.choice(string.ascii_letters + string.digits) for _ in range($length)))" 2>/dev/null)
    fi

    if [[ -z "$password" ]] || [[ ${#password} -lt "$length" ]]; then
        error "Failed to generate secure password."
        exit 1
    fi

    echo "$password"
}

# =============================================================================
# DEPENDENCY CHECKS
# =============================================================================
check_node() {
    if command -v node &>/dev/null; then
        local version=$(node -v | grep -oE '[0-9]+' | head -1)
        if [[ "$version" -ge 18 ]]; then
            log "Node.js $(node -v) found"
            return 0
        else
            warn "Node.js $(node -v) found but v18+ required"
            return 1
        fi
    fi
    return 1
}

check_postgresql() {
    if command -v psql &>/dev/null; then
        local version=$(psql --version | grep -oE '[0-9]+' | head -1)
        if [[ "$version" -ge 14 ]]; then
            log "PostgreSQL $version found"
            return 0
        else
            warn "PostgreSQL $version found but v14+ required"
            return 1
        fi
    fi
    return 1
}

check_pm2() {
    if command -v pm2 &>/dev/null; then
        log "PM2 $(pm2 -v) found"
        return 0
    fi
    return 1
}

# =============================================================================
# INSTALLATION FUNCTIONS
# =============================================================================
install_node() {
    header "Installing Node.js"

    case "$OS" in
        debian)
            curl -fsSL https://deb.nodesource.com/setup_20.x | sudo -E bash -
            sudo $PKG_INSTALL nodejs
            ;;
        rhel)
            curl -fsSL https://rpm.nodesource.com/setup_20.x | sudo bash -
            sudo $PKG_INSTALL nodejs
            ;;
        macos)
            $PKG_INSTALL node@20
            ;;
    esac

    log "Node.js $(node -v) installed"
}

install_postgresql() {
    header "Installing PostgreSQL"

    case "$OS" in
        debian)
            sudo $PKG_INSTALL postgresql postgresql-contrib
            sudo systemctl enable postgresql
            sudo systemctl start postgresql
            ;;
        rhel)
            sudo $PKG_INSTALL postgresql-server postgresql-contrib
            sudo postgresql-setup --initdb || true
            sudo systemctl enable postgresql
            sudo systemctl start postgresql
            ;;
        macos)
            $PKG_INSTALL postgresql@16
            brew services start postgresql@16
            ;;
    esac

    log "PostgreSQL installed and started"
}

install_pm2() {
    header "Installing PM2"
    sudo npm install -g pm2
    log "PM2 $(pm2 -v) installed"
}

# =============================================================================
# DATABASE SETUP
# =============================================================================
setup_database() {
    header "Setting up PostgreSQL Database"

    local db_password=$(generate_secure_password 32)

    # Store password for later use
    DB_PASSWORD="$db_password"

    # Create database and user
    if [[ "$OS" == "macos" ]]; then
        # macOS: current user is superuser
        psql postgres << EOF
SELECT 'CREATE DATABASE ${DB_NAME}' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${DB_NAME}')\gexec

DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${DB_USER}') THEN
        CREATE USER ${DB_USER} WITH PASSWORD '${db_password}';
    ELSE
        ALTER USER ${DB_USER} WITH PASSWORD '${db_password}';
    END IF;
END
\$\$;

REVOKE ALL ON DATABASE ${DB_NAME} FROM PUBLIC;
GRANT CONNECT ON DATABASE ${DB_NAME} TO ${DB_USER};
EOF
    else
        # Linux: use sudo -u postgres
        sudo -u postgres psql << EOF
SELECT 'CREATE DATABASE ${DB_NAME}' WHERE NOT EXISTS (SELECT FROM pg_database WHERE datname = '${DB_NAME}')\gexec

DO \$\$
BEGIN
    IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '${DB_USER}') THEN
        CREATE USER ${DB_USER} WITH PASSWORD '${db_password}';
    ELSE
        ALTER USER ${DB_USER} WITH PASSWORD '${db_password}';
    END IF;
END
\$\$;

REVOKE ALL ON DATABASE ${DB_NAME} FROM PUBLIC;
GRANT CONNECT ON DATABASE ${DB_NAME} TO ${DB_USER};
EOF
    fi

    log "Database ${DB_NAME} and user ${DB_USER} created"
}

run_migrations() {
    header "Running Database Migrations"

    local migrations_dir="$(dirname "$0")/migrations"

    if [[ ! -d "$migrations_dir" ]]; then
        error "Migrations directory not found: $migrations_dir"
        exit 1
    fi

    # Run all migration files in order
    for migration_file in "$migrations_dir"/*.sql; do
        if [[ ! -f "$migration_file" ]]; then
            continue
        fi

        local migration_name=$(basename "$migration_file")
        log "Applying migration: $migration_name"

        if [[ "$OS" == "macos" ]]; then
            if ! psql -d "$DB_NAME" < "$migration_file"; then
                error "Migration $migration_name failed"
                log "Check migration file: $migration_file"
                exit 1
            fi
        else
            if ! sudo -u postgres psql -d "$DB_NAME" < "$migration_file"; then
                error "Migration $migration_name failed"
                log "Check migration file: $migration_file"
                exit 1
            fi
        fi
    done

    # Grant privileges after all migrations complete
    log "Granting database privileges to ${DB_USER}"
    if [[ "$OS" == "macos" ]]; then
        psql -d "$DB_NAME" << EOF
GRANT USAGE ON SCHEMA public TO ${DB_USER};
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO ${DB_USER};
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO ${DB_USER};
GRANT SELECT ON ALL VIEWS IN SCHEMA public TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON VIEWS TO ${DB_USER};
EOF
    else
        sudo -u postgres psql -d "$DB_NAME" << EOF
GRANT USAGE ON SCHEMA public TO ${DB_USER};
GRANT SELECT, INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public TO ${DB_USER};
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO ${DB_USER};
GRANT SELECT ON ALL VIEWS IN SCHEMA public TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT, INSERT, UPDATE, DELETE ON TABLES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT USAGE, SELECT ON SEQUENCES TO ${DB_USER};
ALTER DEFAULT PRIVILEGES IN SCHEMA public GRANT SELECT ON VIEWS TO ${DB_USER};
EOF
    fi

    log "All migrations applied successfully"
}

# =============================================================================
# APPLICATION SETUP
# =============================================================================
setup_application() {
    header "Setting up Application"

    # Create directories
    sudo mkdir -p "$INSTALL_DIR/logs"
    sudo mkdir -p "$INSTALL_DIR/frontend"

    # Copy server files
    local script_dir="$(dirname "$0")"

    if [[ -f "$script_dir/../server/server.js" ]]; then
        sudo cp "$script_dir/../server/server.js" "$INSTALL_DIR/"
        sudo cp "$script_dir/../server/package.json" "$INSTALL_DIR/"
        log "Server files copied"
    else
        error "server.js not found. Please ensure the PDev Live source is available."
        exit 1
    fi

    # Generate admin key
    local admin_key=$(generate_secure_password 32)

    # Create .env file
    sudo tee "$INSTALL_DIR/.env" > /dev/null << EOF
# PDev Live Configuration
# Generated: $(date -u +"%Y-%m-%dT%H:%M:%SZ")

# Database
PDEV_DB_HOST=localhost
PDEV_DB_PORT=5432
PDEV_DB_NAME=${DB_NAME}
PDEV_DB_USER=${DB_USER}
PDEV_DB_PASSWORD=${DB_PASSWORD}

# Server
PORT=${PORT}
NODE_ENV=production

# Security
PDEV_ADMIN_KEY=${admin_key}

# Frontend (optional)
PDEV_FRONTEND_DIR=${INSTALL_DIR}/frontend
EOF

    # Secure .env file
    sudo chmod 600 "$INSTALL_DIR/.env"

    log ".env file created with secure permissions (600)"

    # Install npm dependencies
    cd "$INSTALL_DIR"
    sudo npm install --production

    log "Dependencies installed"

    # Copy auto-update script
    local script_dir="$(dirname "$0")"
    if [[ -f "$script_dir/pdev-update.sh" ]]; then
        sudo cp "$script_dir/pdev-update.sh" "$INSTALL_DIR/"
        sudo chmod +x "$INSTALL_DIR/pdev-update.sh"
        log "Auto-update script installed"
    fi
}

create_ecosystem_config() {
    header "Creating PM2 Configuration"

    sudo tee "$INSTALL_DIR/ecosystem.config.js" > /dev/null << 'EOF'
module.exports = {
  apps: [{
    name: 'pdev-live',
    script: 'server.js',
    cwd: process.env.INSTALL_DIR || '/opt/services/pdev-live',
    exec_mode: 'fork',
    instances: 1,

    // Restart Policy
    autorestart: true,
    max_restarts: 10,
    min_uptime: '60s',
    exp_backoff_restart_delay: 30000,

    // Graceful Shutdown
    kill_timeout: 5000,
    listen_timeout: 10000,

    // Environment
    env_production: {
      NODE_ENV: 'production'
    },

    // Logging
    error_file: 'logs/error.log',
    out_file: 'logs/out.log',
    merge_logs: true,
    log_date_format: 'YYYY-MM-DD HH:mm:ss Z',

    // Memory Management
    max_memory_restart: '500M',

    // Safety
    watch: false
  }]
};
EOF

    # Update cwd in config
    sudo sed -i.bak "s|/opt/services/pdev-live|${INSTALL_DIR}|g" "$INSTALL_DIR/ecosystem.config.js"
    sudo rm -f "$INSTALL_DIR/ecosystem.config.js.bak"

    log "ecosystem.config.js created"
}

# =============================================================================
# DESKTOP APP CONFIGURATION
# =============================================================================
setup_desktop_config() {
    header "Configuring Desktop App"

    # Determine user data directory for Electron app
    local config_dir=""
    case "$OS" in
        macos)
            config_dir="$HOME/Library/Application Support/pdev-live"
            ;;
        debian|rhel)
            config_dir="$HOME/.config/pdev-live"
            ;;
    esac

    if [[ -z "$config_dir" ]]; then
        warn "Could not determine desktop app config directory"
        return
    fi

    # Create config directory
    mkdir -p "$config_dir"

    # Create config.json pointing to local server
    cat > "$config_dir/config.json" << EOF
{
  "serverUrl": "http://localhost:${PORT}"
}
EOF

    chmod 600 "$config_dir/config.json"
    log "Desktop app configured to use http://localhost:${PORT}"
}

# =============================================================================
# SERVICE MANAGEMENT
# =============================================================================
start_service() {
    header "Starting PDev Live Service"

    cd "$INSTALL_DIR"

    # Start with PM2
    if ! pm2 start ecosystem.config.js --env production; then
        error "Failed to start PM2 process"
        log "Checking logs for errors..."
        pm2 logs pdev-live --lines 50 --nostream || true
        log ""
        log "Troubleshooting steps:"
        log "1. Check database connection: PGPASSWORD=\$PDEV_DB_PASSWORD psql -h localhost -U $DB_USER -d $DB_NAME -c 'SELECT 1'"
        log "2. Check port availability: lsof -i :${PORT} (ensure port ${PORT} is free)"
        log "3. Check environment: cat $INSTALL_DIR/.env"
        log "4. View full logs: pm2 logs pdev-live"
        exit 1
    fi

    # Save PM2 configuration
    pm2 save

    log "Service started successfully"
}

setup_startup() {
    header "Configuring Startup"

    if [[ "$OS" != "macos" ]]; then
        # Generate startup script
        pm2 startup systemd -u "$USER" --hp "$HOME" | tail -1 | bash
        log "PM2 startup configured for systemd"
    else
        log "On macOS, run 'pm2 startup' manually to configure LaunchAgent"
    fi
}

setup_auto_updates() {
    header "Configuring Auto-Updates"

    local cron_job="0 * * * * PDEV_INSTALL_DIR=${INSTALL_DIR} ${INSTALL_DIR}/pdev-update.sh >> ${INSTALL_DIR}/logs/update.log 2>&1"

    case "$OS" in
        debian|rhel)
            # Add to crontab
            (crontab -l 2>/dev/null | grep -v "pdev-update.sh"; echo "$cron_job") | crontab -
            log "Cron job added for hourly update checks"
            ;;
        macos)
            # Create launchd plist for macOS
            local plist_path="$HOME/Library/LaunchAgents/com.pdev.update.plist"
            cat > "$plist_path" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>com.pdev.update</string>
    <key>ProgramArguments</key>
    <array>
        <string>${INSTALL_DIR}/pdev-update.sh</string>
    </array>
    <key>EnvironmentVariables</key>
    <dict>
        <key>PDEV_INSTALL_DIR</key>
        <string>${INSTALL_DIR}</string>
    </dict>
    <key>StartInterval</key>
    <integer>3600</integer>
    <key>StandardOutPath</key>
    <string>${INSTALL_DIR}/logs/update.log</string>
    <key>StandardErrorPath</key>
    <string>${INSTALL_DIR}/logs/update.log</string>
    <key>RunAtLoad</key>
    <true/>
</dict>
</plist>
EOF
            launchctl load "$plist_path"
            log "LaunchAgent configured for hourly update checks"
            ;;
    esac
}

# =============================================================================
# HEALTH CHECK
# =============================================================================
wait_for_health() {
    local max_attempts="${1:-30}"
    local delay="${2:-2}"
    local attempt=1

    log "Waiting for service to be ready..."

    while [[ $attempt -le $max_attempts ]]; do
        if curl -sf "http://localhost:${PORT}/health" > /dev/null 2>&1; then
            log "Health check passed!"
            return 0
        fi

        echo -n "."
        sleep "$delay"
        ((attempt++))
    done

    echo ""
    error "Health check failed after $max_attempts attempts"
    pm2 logs pdev-live --lines 20 --nostream
    return 1
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    parse_args "$@"

    header "PDev Live Self-Hosted Installer v${VERSION}"

    # Detect OS first (required for other checks)
    detect_os

    # Check if running as root
    if [[ "$EUID" -eq 0 ]] && [[ "$OS" != "macos" ]]; then
        warn "Running as root. Service will run as root user."
    fi

    # Check and install dependencies
    header "Checking Dependencies"

    if ! check_node; then
        if prompt_user "Node.js 18+ not found. Install it?" "Y"; then
            install_node
        else
            error "Node.js is required. Aborting."
            exit 1
        fi
    fi

    if ! check_postgresql; then
        if prompt_user "PostgreSQL 14+ not found. Install it?" "Y"; then
            install_postgresql
        else
            error "PostgreSQL is required. Aborting."
            exit 1
        fi
    fi

    if ! check_pm2; then
        if prompt_user "PM2 not found. Install it?" "Y"; then
            install_pm2
        else
            error "PM2 is required. Aborting."
            exit 1
        fi
    fi

    # Setup database
    setup_database
    run_migrations

    # Setup application
    setup_application
    create_ecosystem_config

    # Configure desktop app
    setup_desktop_config

    # Start service
    start_service

    # Wait for health
    if wait_for_health 30 2; then
        # Setup startup
        if prompt_user "Configure automatic startup on boot?" "Y"; then
            setup_startup
        fi

        # Setup auto-updates
        if prompt_user "Enable automatic updates (hourly check)?" "Y"; then
            setup_auto_updates
        fi

        header "Installation Complete!"
        echo ""
        log "PDev Live is running at: http://localhost:${PORT}"
        log "Health endpoint: http://localhost:${PORT}/health"
        log "Installation directory: ${INSTALL_DIR}"
        echo ""
        log "Useful commands:"
        echo "  pm2 status pdev-live      # Check status"
        echo "  pm2 logs pdev-live        # View logs"
        echo "  pm2 restart pdev-live     # Restart service"
        echo "  $INSTALL_DIR/pdev-update.sh --check  # Check for updates"
        echo ""
        log "Admin key stored in: ${INSTALL_DIR}/.env"
        log "Desktop app will connect to: http://localhost:${PORT}"
    else
        error "Service failed to start. Check logs above."
        exit 1
    fi
}

main "$@"
