#!/usr/bin/env bash
#
# ============================================================================
# PDev-Live One-Command Installer
# ============================================================================
# Version: 1.0.0
# Description: Downloads and installs PDev-Live (source or project mode)
#
# Usage:
#   Interactive:  curl -fsSL https://vyxenai.com/pdev/install.sh | sudo bash
#   Source mode:  curl -fsSL https://vyxenai.com/pdev/install.sh | sudo bash -s -- --domain pdev.example.com
#   Project mode: curl -fsSL https://vyxenai.com/pdev/install.sh | sudo bash -s -- --source-url https://pdev.example.com/pdev/api
#
# ============================================================================

set -euo pipefail
IFS=$'\n\t'

# =============================================================================
# CONFIGURATION
# =============================================================================
VERSION="1.0.0"
INSTALLER_URL="https://vyxenai.com/pdev/install/pdev-partner-installer.tar.gz"
INSTALLER_SHA256="3c7a28425532096bc97a52afcb59d40946bfbf86ee1e0e6578cc739f93fcb3f1"
TEMP_DIR=""
LOG_FILE=$(mktemp /tmp/pdev-install-wrapper.XXXXXX.log)

# Runtime flags (populated from arguments or interactive prompts)
MODE=""
DOMAIN=""
SOURCE_URL=""
EXTRA_ARGS=()

# =============================================================================
# UTILITIES
# =============================================================================

log() {
    echo "[$(date +'%Y-%m-%d %H:%M:%S')] $*" | tee -a "$LOG_FILE"
}

error() {
    echo "❌ ERROR: $*" | tee -a "$LOG_FILE" >&2
}

success() {
    echo "✅ $*" | tee -a "$LOG_FILE"
}

warn() {
    echo "⚠️  WARNING: $*" | tee -a "$LOG_FILE"
}

header() {
    echo ""
    echo "━━━ $* ━━━"
    echo ""
}

fail() {
    error "$@"
    cleanup_and_exit 1
}

cleanup_and_exit() {
    local exit_code="${1:-0}"

    if [[ -n "${TEMP_DIR:-}" && -d "$TEMP_DIR" ]]; then
        log "Cleaning up temporary files: $TEMP_DIR"
        rm -rf "$TEMP_DIR" 2>/dev/null || true
    fi

    if [[ $exit_code -eq 0 ]]; then
        success "Installation completed successfully!"
    else
        error "Installation failed. Log file: $LOG_FILE"
    fi

    exit "$exit_code"
}

# Trap cleanup on exit
trap 'cleanup_and_exit $?' EXIT INT TERM

# =============================================================================
# PREREQUISITE CHECKS
# =============================================================================

check_prerequisites() {
    header "Checking Prerequisites"

    # Check root
    if [[ $EUID -ne 0 ]]; then
        fail "This installer must be run as root (use sudo)"
    fi
    success "Running as root"

    # Check curl
    if ! command -v curl &>/dev/null; then
        fail "curl not found. Install with: apt-get install -y curl"
    fi
    success "curl available"

    # Check tar
    if ! command -v tar &>/dev/null; then
        fail "tar not found. Install with: apt-get install -y tar"
    fi
    success "tar available"

    # Check disk space (need at least 100MB for temp files)
    local available_kb
    available_kb=$(df /tmp | awk 'NR==2 {print $4}')
    if [[ $available_kb -lt 102400 ]]; then
        fail "Insufficient disk space in /tmp (need 100MB, have $((available_kb/1024))MB)"
    fi
    success "Sufficient disk space available"
}

# =============================================================================
# INTERACTIVE MODE SELECTION
# =============================================================================

prompt_mode_selection() {
    if [[ -n "$DOMAIN" || -n "$SOURCE_URL" ]]; then
        # Non-interactive mode (flags provided)
        return 0
    fi

    header "PDev-Live Installation Mode"

    echo "Choose installation mode:"
    echo ""
    echo "  1) Source Server (Full Stack)"
    echo "     - Hosts PDev-Live backend (database, nginx, PM2, API)"
    echo "     - Requires: Domain name, PostgreSQL, nginx, Node.js"
    echo "     - Use case: Central server hosting PDev-Live"
    echo ""
    echo "  2) Project Server (Client Only)"
    echo "     - Installs CLI client only (posts to source server)"
    echo "     - Requires: bash, curl"
    echo "     - Use case: Multiple project servers → central source"
    echo ""

    while true; do
        read -p "Select mode [1 or 2]: " mode_choice

        case "$mode_choice" in
            1)
                MODE="source"
                echo ""
                read -p "Enter your domain (e.g., pdev.example.com): " DOMAIN

                if [[ -z "$DOMAIN" ]]; then
                    error "Domain cannot be empty"
                    continue
                fi

                # Validate domain format
                if [[ ! "$DOMAIN" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
                    error "Invalid domain format. Use: subdomain.example.com"
                    continue
                fi

                success "Source mode selected: $DOMAIN"
                break
                ;;
            2)
                MODE="project"
                echo ""
                read -p "Enter source server URL (e.g., https://pdev.example.com/pdev/api): " SOURCE_URL

                if [[ -z "$SOURCE_URL" ]]; then
                    error "Source URL cannot be empty"
                    continue
                fi

                if [[ ! "$SOURCE_URL" =~ ^https?:// ]]; then
                    error "Source URL must start with http:// or https://"
                    continue
                fi

                # Validate URL format
                if [[ ! "$SOURCE_URL" =~ ^https?://[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}(/.*)?$ ]]; then
                    error "Invalid URL format. Must be valid HTTP(S) URL"
                    continue
                fi

                success "Project mode selected: $SOURCE_URL"
                break
                ;;
            *)
                error "Invalid choice. Please enter 1 or 2"
                ;;
        esac
    done
}

# =============================================================================
# DOWNLOAD AND EXTRACT
# =============================================================================

download_installer() {
    header "Downloading PDev-Live Installer"

    # Create temp directory
    TEMP_DIR=$(mktemp -d /tmp/pdev-install.XXXXXX)
    log "Created temp directory: $TEMP_DIR"

    local tarball="$TEMP_DIR/pdev-partner-installer.tar.gz"

    log "Downloading from: $INSTALLER_URL"
    if ! curl -fsSL --max-time 300 --retry 3 -o "$tarball" "$INSTALLER_URL"; then
        fail "Failed to download installer from $INSTALLER_URL"
    fi

    # Verify download exists
    if [[ ! -f "$tarball" ]]; then
        fail "Downloaded file not found: $tarball"
    fi

    # Verify checksum (if SHA256 is set)
    if [[ -n "$INSTALLER_SHA256" ]]; then
        log "Verifying integrity..."
        if command -v sha256sum &>/dev/null; then
            echo "$INSTALLER_SHA256  $tarball" | sha256sum -c - || fail "Checksum verification failed"
        elif command -v shasum &>/dev/null; then
            echo "$INSTALLER_SHA256  $tarball" | shasum -a 256 -c - || fail "Checksum verification failed"
        else
            warn "sha256sum not available - skipping integrity check (UNSAFE)"
        fi
        success "Downloaded installer (verified)"
    else
        local size_kb
        if [[ "$OSTYPE" == "darwin"* ]]; then
            size_kb=$(($(stat -f%z "$tarball") / 1024))
        else
            size_kb=$(($(stat -c%s "$tarball") / 1024))
        fi
        warn "Downloaded installer ($size_kb KB) - NO CHECKSUM VERIFICATION"
    fi

    # Extract
    log "Extracting installer..."
    if ! tar -xzf "$tarball" -C "$TEMP_DIR"; then
        fail "Failed to extract installer tarball"
    fi

    success "Installer extracted to $TEMP_DIR"
}

# =============================================================================
# RUN INSTALLER
# =============================================================================

run_installer() {
    header "Running PDev-Live Installer"

    local installer_script="$TEMP_DIR/installer/pdl-installer.sh"

    if [[ ! -f "$installer_script" ]]; then
        fail "Installer script not found: $installer_script"
    fi

    chmod +x "$installer_script"

    # Build arguments for pdl-installer.sh
    local args=()

    if [[ -n "$DOMAIN" ]]; then
        args+=("--domain" "$DOMAIN")
    fi

    if [[ -n "$SOURCE_URL" ]]; then
        args+=("--source-url" "$SOURCE_URL")
    fi

    # Add any extra arguments passed to wrapper
    args+=("${EXTRA_ARGS[@]}")

    log "Running: $installer_script ${args[*]}"

    # Run installer in subshell to avoid changing working directory
    (cd "$TEMP_DIR/installer" && bash "$installer_script" "${args[@]}")

    success "Installer completed successfully"
}

# =============================================================================
# ARGUMENT PARSING
# =============================================================================

parse_arguments() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --domain)
                if [[ -z "${2:-}" ]]; then
                    fail "--domain requires an argument"
                fi
                if [[ ! "$2" =~ ^[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}$ ]]; then
                    fail "Invalid --domain value: $2"
                fi
                DOMAIN="$2"
                MODE="source"
                shift 2
                ;;
            --source-url)
                if [[ -z "${2:-}" ]]; then
                    fail "--source-url requires an argument"
                fi
                if [[ ! "$2" =~ ^https?://[a-zA-Z0-9][a-zA-Z0-9.-]+\.[a-zA-Z]{2,}(/.*)?$ ]]; then
                    fail "Invalid --source-url value: $2"
                fi
                SOURCE_URL="$2"
                MODE="project"
                shift 2
                ;;
            --non-interactive|--dry-run|--force|--help)
                # Pass through to pdl-installer.sh
                EXTRA_ARGS+=("$1")
                shift
                ;;
            --*)
                # Pass through any other flags
                EXTRA_ARGS+=("$1")
                if [[ $# -gt 1 && ! "$2" =~ ^-- ]]; then
                    EXTRA_ARGS+=("$2")
                    shift
                fi
                shift
                ;;
            *)
                error "Unknown argument: $1"
                shift
                ;;
        esac
    done
}

# =============================================================================
# MAIN
# =============================================================================

main() {
    header "PDev-Live One-Command Installer v$VERSION"

    # Parse command-line arguments
    parse_arguments "$@"

    # Check prerequisites
    check_prerequisites

    # Interactive mode selection if no flags provided
    prompt_mode_selection

    # Download and extract installer
    download_installer

    # Run the actual installer
    run_installer

    # Cleanup happens via trap on exit
}

# Run main
main "$@"
