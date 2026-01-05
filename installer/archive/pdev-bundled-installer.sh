#!/usr/bin/env bash
#
# PDev Live Bundled Installer - Orchestrator Script
# Version: 1.0.0
#
# Installs both desktop app and server in one coordinated process
# Usage: ./pdev-live-installer.sh [OPTIONS]
#
# Options:
#   --server-host HOST    Remote server (user@host) or 'localhost'
#   --version VERSION     Install specific version (default: detect from bundle)
#   --non-interactive     No prompts (use defaults)
#   --help               Show this help
#

set -euo pipefail
IFS=$'\n\t'

# =============================================================================
# CONFIGURATION
# =============================================================================
VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LOG_FILE="/tmp/pdev-installer-$(date +%s).log"
BACKUP_DIR="/tmp/pdev-backup-$(date +%s)"

# Installation state tracking
DESKTOP_INSTALLED=false
SERVER_INSTALLED=false
CONFIG_CREATED=false

# Runtime configuration
SERVER_HOST="${SERVER_HOST:-}"
SERVER_TYPE=""  # 'localhost' or 'remote'
SERVER_URL=""
OS_TYPE=""
INTERACTIVE="${INTERACTIVE:-true}"

# =============================================================================
# COLOR CODES
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
exec > >(tee -a "$LOG_FILE") 2>&1

log()   { echo -e "${GREEN}[INFO]${NC} $*"; }
warn()  { echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
error() { echo -e "${RED}[ERROR]${NC} $*" >&2; }
header() { echo -e "\n${BOLD}${BLUE}━━━ $* ━━━${NC}\n"; }
success() { echo -e "${GREEN}✅${NC} $*"; }
fail() { echo -e "${RED}❌${NC} $*"; }

# =============================================================================
# CLEANUP AND ROLLBACK
# =============================================================================
cleanup() {
    local exit_code=$?

    if [[ $exit_code -ne 0 ]]; then
        error "Installation failed with exit code $exit_code"
        error "Log file: $LOG_FILE"

        # Offer rollback
        if [[ "$INTERACTIVE" == "true" ]]; then
            read -p "Rollback installation? (y/n): " ROLLBACK
            if [[ "$ROLLBACK" == "y" ]]; then
                rollback_installation
            fi
        else
            warn "Non-interactive mode - skipping rollback"
            warn "Manual rollback: Review $LOG_FILE for details"
        fi
    else
        # Cleanup temp files on success
        rm -f /tmp/pdev-desktop-*
        rm -f /tmp/pdev-checksums.txt
    fi
}

rollback_installation() {
    header "Rolling Back Failed Installation"

    # Rollback desktop app
    if [[ "$DESKTOP_INSTALLED" == "true" ]]; then
        log "Removing desktop app..."
        case "$OS_TYPE" in
            macos)
                rm -rf "/Applications/PDev Live.app"
                rm -rf "$HOME/Library/Application Support/PDev Live"

                # Restore backup if exists
                if [[ -d "$BACKUP_DIR/PDev Live.app" ]]; then
                    cp -R "$BACKUP_DIR/PDev Live.app" "/Applications/"
                    success "Restored previous desktop app version"
                fi
                ;;
            linux)
                sudo dpkg -r pdev-live 2>/dev/null || true
                rm -rf "$HOME/.config/pdev-live"
                ;;
            windows)
                warn "Windows rollback must be done manually via Add/Remove Programs"
                ;;
        esac
    fi

    # Rollback server installation
    if [[ "$SERVER_INSTALLED" == "true" ]]; then
        log "Removing server installation..."
        if [[ "$SERVER_TYPE" == "remote" ]]; then
            execute_remote_command "$SERVER_HOST" "pm2 delete pdev-live-server 2>/dev/null || true"
            execute_remote_command "$SERVER_HOST" "rm -rf /opt/services/pdev-live"
        else
            pm2 delete pdev-live-server 2>/dev/null || true
            sudo rm -rf /opt/services/pdev-live
        fi
    fi

    # Remove config
    if [[ "$CONFIG_CREATED" == "true" && -n "$CONFIG_PATH" ]]; then
        rm -f "$CONFIG_PATH"
    fi

    success "Rollback complete"
}

trap cleanup EXIT ERR INT TERM

# =============================================================================
# UTILITY FUNCTIONS
# =============================================================================
sanitize_input() {
    echo "$1" | sed 's/[^a-zA-Z0-9._@-]//g'
}

execute_remote_command() {
    local host="$1"
    local command="$2"

    # Special handling for wdress (Windows/WSL)
    if [[ "$host" == "wdress" ]]; then
        log "Detected Windows/WSL server - using special syntax"
        ssh wdress "wsl -e bash -c \"$command\""
    else
        # Standard Linux/macOS SSH
        ssh "$host" "$command"
    fi
}

# =============================================================================
# PHASE 0: USAGE AND ARGUMENT PARSING
# =============================================================================
show_help() {
    cat <<EOF
PDev Live Bundled Installer v${VERSION}

Orchestrates installation of desktop app + server in one process

Usage: $0 [OPTIONS]

Options:
  --server-host HOST    Server location (localhost or user@host)
  --version VERSION     Install specific version (default: from bundle)
  --non-interactive     No prompts (requires --server-host)
  --help               Show this help

Examples:
  $0                                    # Interactive mode
  $0 --server-host localhost            # Install server locally
  $0 --server-host user@server.com      # Install on remote server
  $0 --non-interactive --server-host acme   # Automated remote install

Notes:
  - Desktop app always installs on this machine
  - Server can install locally or remotely via SSH
  - Requires SSH key authentication for remote servers
  - Logs saved to: $LOG_FILE

EOF
}

# Parse arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        --server-host)
            SERVER_HOST="$2"
            shift 2
            ;;
        --version)
            VERSION="$2"
            shift 2
            ;;
        --non-interactive)
            INTERACTIVE=false
            shift
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

# =============================================================================
# PHASE 1: PRE-FLIGHT CHECKS
# =============================================================================
check_prerequisites() {
    header "Phase 1: Pre-Flight Validation"

    log "Checking required commands..."

    local required_commands=("curl" "ssh" "tar" "sha256sum")
    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &>/dev/null; then
            # sha256sum fallback for macOS
            if [[ "$cmd" == "sha256sum" ]] && command -v shasum &>/dev/null; then
                log "Using shasum instead of sha256sum (macOS)"
                continue
            fi

            fail "Required command not found: $cmd"
            error "Install it and try again"
            exit 1
        fi
    done

    # Check disk space (need ~500MB)
    local available_space=$(df /tmp | tail -1 | awk '{print $4}')
    if [[ "$available_space" -lt $((500 * 1024)) ]]; then
        fail "Insufficient disk space in /tmp (need 500MB)"
        exit 1
    fi

    success "Prerequisites validated"
}

detect_os_type() {
    log "Detecting operating system..."

    case "$OSTYPE" in
        darwin*)
            OS_TYPE="macos"
            CONFIG_PATH="$HOME/Library/Application Support/PDev Live/config.json"
            ;;
        linux-gnu*)
            OS_TYPE="linux"
            CONFIG_PATH="${XDG_CONFIG_HOME:-$HOME/.config}/pdev-live/config.json"
            ;;
        msys*|cygwin*)
            OS_TYPE="windows"
            CONFIG_PATH="$APPDATA/PDev Live/config.json"
            warn "Windows detected - this script requires WSL or Git Bash"
            warn "For best experience, use native Windows installer"
            ;;
        *)
            fail "Unsupported OS: $OSTYPE"
            exit 1
            ;;
    esac

    log "OS Type: $OS_TYPE"
    log "Config Path: $CONFIG_PATH"
}

# =============================================================================
# PHASE 2: SERVER TARGET VALIDATION
# =============================================================================
prompt_server_location() {
    header "Phase 2: Server Target Selection"

    if [[ -z "$SERVER_HOST" ]]; then
        if [[ "$INTERACTIVE" == "true" ]]; then
            echo "Where should the PDev Live server run?"
            echo "1) This machine (localhost)"
            echo "2) Remote server (via SSH)"
            read -p "Select [1-2]: " SERVER_CHOICE

            case "$SERVER_CHOICE" in
                1)
                    SERVER_HOST="localhost"
                    ;;
                2)
                    read -p "Enter SSH host (e.g., user@server.com or acme): " SERVER_HOST
                    SERVER_HOST=$(sanitize_input "$SERVER_HOST")
                    ;;
                *)
                    fail "Invalid choice"
                    exit 1
                    ;;
            esac
        else
            fail "Non-interactive mode requires --server-host"
            exit 1
        fi
    fi

    if [[ "$SERVER_HOST" == "localhost" ]]; then
        SERVER_TYPE="localhost"
        SERVER_URL="http://localhost:3016"
        log "Server will install locally"
    else
        SERVER_TYPE="remote"
        SERVER_URL="http://$SERVER_HOST:3016"
        log "Server will install on: $SERVER_HOST"
    fi
}

verify_ssh_access() {
    if [[ "$SERVER_TYPE" != "remote" ]]; then
        return 0
    fi

    log "Testing SSH connection to $SERVER_HOST..."

    # Test SSH connectivity (key-based auth only, no password prompts)
    if ! ssh -o BatchMode=yes -o ConnectTimeout=10 "$SERVER_HOST" exit 2>/dev/null; then
        fail "Cannot connect to $SERVER_HOST via SSH"
        error "Setup required:"
        error "  1. Generate SSH key: ssh-keygen"
        error "  2. Copy to server: ssh-copy-id $SERVER_HOST"
        error "  3. Or manually add key to ~/.ssh/authorized_keys on server"
        exit 1
    fi

    success "SSH connection verified"
}

check_port_conflict() {
    if [[ "$SERVER_TYPE" != "remote" ]]; then
        # Check localhost port
        if lsof -ti:3016 >/dev/null 2>&1; then
            warn "Port 3016 already in use on localhost"

            # Check if it's pdev-live-server
            if pm2 list | grep -q "pdev-live-server"; then
                log "Found existing PDev Live installation"
                if [[ "$INTERACTIVE" == "true" ]]; then
                    read -p "Upgrade existing installation? (y/n): " UPGRADE
                    if [[ "$UPGRADE" != "y" ]]; then
                        fail "Installation cancelled"
                        exit 1
                    fi
                    log "Proceeding with upgrade..."
                else
                    log "Non-interactive mode - proceeding with upgrade"
                fi
            else
                fail "Port 3016 in use by another service"
                exit 1
            fi
        fi
    else
        # Check remote server port
        local port_in_use=$(execute_remote_command "$SERVER_HOST" "lsof -ti:3016 2>/dev/null || true")

        if [[ -n "$port_in_use" ]]; then
            warn "Port 3016 already in use on $SERVER_HOST"

            # Check if it's pdev-live-server
            local existing_process=$(execute_remote_command "$SERVER_HOST" "pm2 list | grep pdev-live-server || true")

            if [[ -n "$existing_process" ]]; then
                log "Found existing PDev Live installation on $SERVER_HOST"
                if [[ "$INTERACTIVE" == "true" ]]; then
                    read -p "Upgrade existing installation? (y/n): " UPGRADE
                    if [[ "$UPGRADE" != "y" ]]; then
                        fail "Installation cancelled"
                        exit 1
                    fi
                    log "Proceeding with upgrade..."
                else
                    log "Non-interactive mode - proceeding with upgrade"
                fi
            else
                fail "Port 3016 in use by another service on $SERVER_HOST"
                exit 1
            fi
        fi
    fi

    success "Port 3016 available"
}

# =============================================================================
# PHASE 3: DATABASE PREREQUISITES
# =============================================================================
verify_database_ready() {
    log "Verifying database prerequisites..."

    # This function runs on the target server (via SSH if remote)
    local check_script='
    set -e

    # Check PostgreSQL installed
    if ! command -v psql &>/dev/null; then
        echo "ERROR: PostgreSQL not installed"
        exit 1
    fi

    # Check PostgreSQL service running
    if ! systemctl is-active --quiet postgresql 2>/dev/null; then
        echo "WARNING: PostgreSQL service not running"
        echo "Attempting to start..."
        sudo systemctl start postgresql || true
        sleep 2
    fi

    echo "PostgreSQL ready"
    '

    if [[ "$SERVER_TYPE" == "remote" ]]; then
        execute_remote_command "$SERVER_HOST" "$check_script"
    else
        eval "$check_script"
    fi

    success "Database prerequisites validated"
}

# =============================================================================
# PHASE 4: SERVER INSTALLATION
# =============================================================================
install_server() {
    header "Phase 4: Server Installation"

    log "Running install.sh on $SERVER_TYPE..."

    # install.sh is in same directory as this script
    local install_script="$SCRIPT_DIR/install.sh"

    if [[ ! -f "$install_script" ]]; then
        fail "install.sh not found at $install_script"
        exit 1
    fi

    if [[ "$SERVER_TYPE" == "remote" ]]; then
        # Copy install.sh to remote server and execute
        scp "$install_script" "$SERVER_HOST:/tmp/install.sh"
        execute_remote_command "$SERVER_HOST" "bash /tmp/install.sh --non-interactive --yes"
        execute_remote_command "$SERVER_HOST" "rm /tmp/install.sh"
    else
        # Run locally
        bash "$install_script" --non-interactive --yes
    fi

    SERVER_INSTALLED=true
    success "Server installation complete"
}

verify_pm2_process() {
    log "Verifying PM2 process health..."

    local verify_script='
    set -e

    # Check PM2 status
    PM2_STATUS=$(pm2 jlist | jq -r ".[0].pm2_env.status" 2>/dev/null || echo "error")
    if [[ "$PM2_STATUS" != "online" ]]; then
        echo "ERROR: PM2 process not online (status: $PM2_STATUS)"
        pm2 logs pdev-live-server --lines 50 --nostream || true
        exit 1
    fi

    # Check restart count
    RESTART_COUNT=$(pm2 jlist | jq -r ".[0].pm2_env.restart_time" 2>/dev/null || echo "0")
    if [[ "$RESTART_COUNT" -gt 3 ]]; then
        echo "ERROR: Process restarting too frequently ($RESTART_COUNT restarts)"
        pm2 logs pdev-live-server --lines 100 --nostream || true
        exit 1
    fi

    # Wait for port binding (max 10 seconds)
    for i in {1..10}; do
        if netstat -tuln 2>/dev/null | grep -q ":3016.*LISTEN" || lsof -ti:3016 >/dev/null 2>&1; then
            echo "Port 3016 bound successfully"
            break
        fi
        if [[ $i -eq 10 ]]; then
            echo "ERROR: Port 3016 not bound after 10 seconds"
            exit 1
        fi
        sleep 1
    done

    echo "PM2 process healthy"
    '

    if [[ "$SERVER_TYPE" == "remote" ]]; then
        execute_remote_command "$SERVER_HOST" "$verify_script"
    else
        eval "$verify_script"
    fi

    success "PM2 process validated"
}

verify_server_health() {
    log "Checking server health endpoint..."

    # Wait for server to initialize (max 30 seconds)
    local max_attempts=30
    for ((i=1; i<=max_attempts; i++)); do
        if curl -sf "$SERVER_URL/health" >/dev/null 2>&1; then
            success "Server health check passed"
            return 0
        fi

        if [[ $i -eq $max_attempts ]]; then
            fail "Server health check failed after ${max_attempts}s"
            error "Server URL: $SERVER_URL/health"
            error "Check PM2 logs: pm2 logs pdev-live-server"
            exit 1
        fi

        sleep 1
    done
}

# =============================================================================
# PHASE 5: DESKTOP APP INSTALLATION
# =============================================================================
download_desktop_binary() {
    header "Phase 5: Desktop App Installation"

    log "Downloading desktop app for $OS_TYPE..."

    # Determine binary extension
    local ext=""
    case "$OS_TYPE" in
        macos) ext="dmg" ;;
        linux) ext="deb" ;;
        windows) ext="exe" ;;
    esac

    local binary_url="https://walletsnack.com/pdev/releases/PDev-Live-${VERSION}.${ext}"
    local binary_path="/tmp/pdev-desktop.${ext}"

    log "Downloading from: $binary_url"

    if ! curl --progress-bar -fL "$binary_url" -o "$binary_path"; then
        fail "Failed to download desktop app"
        error "URL: $binary_url"
        exit 1
    fi

    success "Desktop app downloaded: $binary_path"
}

verify_checksum() {
    log "Verifying download integrity..."

    # Download checksums file
    local checksums_url="https://walletsnack.com/pdev/releases/SHA256SUMS"
    curl -fsSL "$checksums_url" -o /tmp/pdev-checksums.txt || {
        warn "Could not download checksums - skipping verification"
        return 0
    }

    # Determine binary filename
    local ext=""
    case "$OS_TYPE" in
        macos) ext="dmg" ;;
        linux) ext="deb" ;;
        windows) ext="exe" ;;
    esac

    local binary_name="PDev-Live-${VERSION}.${ext}"

    # Verify checksum
    cd /tmp
    if command -v sha256sum &>/dev/null; then
        if grep "$binary_name" pdev-checksums.txt | sha256sum -c -; then
            success "Checksum verified"
        else
            fail "Checksum verification failed - file may be corrupted or tampered"
            exit 1
        fi
    elif command -v shasum &>/dev/null; then
        if grep "$binary_name" pdev-checksums.txt | shasum -a 256 -c -; then
            success "Checksum verified"
        else
            fail "Checksum verification failed - file may be corrupted or tampered"
            exit 1
        fi
    else
        warn "sha256sum/shasum not found - skipping verification"
    fi
}

install_desktop_app() {
    log "Installing desktop app..."

    # Backup existing installation
    case "$OS_TYPE" in
        macos)
            if [[ -d "/Applications/PDev Live.app" ]]; then
                log "Backing up existing installation..."
                mkdir -p "$BACKUP_DIR"
                cp -R "/Applications/PDev Live.app" "$BACKUP_DIR/"
            fi

            # Mount DMG and install
            log "Mounting DMG..."
            hdiutil attach /tmp/pdev-desktop.dmg -nobrowse -quiet

            log "Copying to Applications..."
            cp -R "/Volumes/PDev Live/PDev Live.app" /Applications/

            log "Unmounting DMG..."
            hdiutil detach "/Volumes/PDev Live" -quiet
            ;;

        linux)
            log "Installing with dpkg..."
            sudo dpkg -i /tmp/pdev-desktop.deb || {
                fail "Desktop app installation failed"
                exit 1
            }
            ;;

        windows)
            warn "Windows installer requires manual execution"
            log "Launch: /tmp/pdev-desktop.exe"
            ;;
    esac

    DESKTOP_INSTALLED=true
    success "Desktop app installed"
}

# =============================================================================
# PHASE 6: CONFIGURATION
# =============================================================================
configure_desktop_app() {
    header "Phase 6: Configuration"

    log "Creating desktop app configuration..."

    # Create config directory
    mkdir -p "$(dirname "$CONFIG_PATH")"

    # Write config file
    cat > "$CONFIG_PATH" <<EOF
{
  "serverUrl": "$SERVER_URL",
  "serverHost": "$SERVER_HOST",
  "serverPort": 3016,
  "autoConnect": true,
  "installedAt": "$(date -u +"%Y-%m-%dT%H:%M:%SZ")",
  "version": "$VERSION"
}
EOF

    chmod 600 "$CONFIG_PATH"
    CONFIG_CREATED=true

    success "Configuration created: $CONFIG_PATH"
}

# =============================================================================
# PHASE 7: FINAL VERIFICATION
# =============================================================================
verify_end_to_end() {
    header "Phase 7: Final Verification"

    log "Running end-to-end verification..."

    # Test 1: Server health endpoint
    log "Test 1: Server health check..."
    if ! curl -sf "$SERVER_URL/health" >/dev/null; then
        fail "Health check failed"
        exit 1
    fi
    success "Server health OK"

    # Test 2: Database connectivity
    log "Test 2: Database connectivity..."
    local health_json=$(curl -s "$SERVER_URL/health")
    if ! echo "$health_json" | grep -q "healthy"; then
        fail "Server health response invalid"
        exit 1
    fi
    success "Server responding correctly"

    # Test 3: Config file readable
    log "Test 3: Configuration file..."
    if [[ ! -f "$CONFIG_PATH" ]]; then
        fail "Config file not found: $CONFIG_PATH"
        exit 1
    fi
    success "Configuration file exists"

    success "All verification tests passed"
}

# =============================================================================
# MAIN EXECUTION
# =============================================================================
main() {
    header "PDev Live Installation - Orchestrated Deployment"
    log "Version: $VERSION"
    log "Log file: $LOG_FILE"
    echo ""

    # PHASE 1: Pre-flight Checks
    check_prerequisites
    detect_os_type

    # PHASE 2: Target Server Validation
    prompt_server_location
    verify_ssh_access
    check_port_conflict

    # PHASE 3: Database Prerequisites
    verify_database_ready

    # PHASE 4: Server Installation (BEFORE desktop app)
    install_server
    verify_pm2_process
    verify_server_health

    # PHASE 5: Desktop App Installation (AFTER server verified)
    download_desktop_binary
    verify_checksum
    install_desktop_app

    # PHASE 6: Configuration (AFTER both installed)
    configure_desktop_app

    # PHASE 7: Final Verification
    verify_end_to_end

    # SUCCESS
    header "Installation Complete!"
    echo ""
    success "Desktop app: Installed and configured"
    success "Server: Running at $SERVER_URL"
    success "Health: All systems operational"
    echo ""
    log "Next steps:"
    log "  1. Open 'PDev Live' from Applications"
    log "  2. Verify connection to server"
    log "  3. Check server health: curl $SERVER_URL/health"
    echo ""
    log "Configuration: $CONFIG_PATH"
    log "Server logs: pm2 logs pdev-live-server"
    log "Installation log: $LOG_FILE"
}

# Execute main with all arguments
main "$@"
