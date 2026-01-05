#!/usr/bin/env bash
#
# PDev Live Auto-Update Script
# Checks vyxenai.com for new versions and auto-updates if available
#
# Usage:
#   ./pdev-update.sh              # Check and update if needed
#   ./pdev-update.sh --check      # Check only, don't update
#   ./pdev-update.sh --force      # Force update even if same version
#
# Cron example (check every hour):
#   0 * * * * /opt/services/pdev-live/pdev-update.sh >> /opt/services/pdev-live/logs/update.log 2>&1
#

set -euo pipefail

# Configuration
INSTALL_DIR="${PDEV_INSTALL_DIR:-/opt/services/pdev-live}"
UPDATE_URL="https://vyxenai.com/pdev/api/version"
UPDATE_FILE_URL="https://vyxenai.com/pdev/api/update-file"
LOG_FILE="$INSTALL_DIR/logs/update.log"

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${GREEN}[INFO]${NC} $*"; }
warn() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${YELLOW}[WARN]${NC} $*" >&2; }
error() { echo -e "[$(date '+%Y-%m-%d %H:%M:%S')] ${RED}[ERROR]${NC} $*" >&2; }

# Parse arguments
CHECK_ONLY=false
FORCE_UPDATE=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --check) CHECK_ONLY=true; shift ;;
        --force) FORCE_UPDATE=true; shift ;;
        *) shift ;;
    esac
done

# Get current local version
get_local_version() {
    if [[ -f "$INSTALL_DIR/server.js" ]]; then
        grep -oP "version:\s*'[0-9.]+'" "$INSTALL_DIR/server.js" | head -1 | grep -oP "[0-9.]+" || echo "0.0.0"
    else
        echo "0.0.0"
    fi
}

# Get remote version from update server
get_remote_version() {
    local response
    response=$(curl -sf --connect-timeout 10 "$UPDATE_URL" 2>/dev/null) || {
        error "Failed to check remote version"
        return 1
    }
    echo "$response" | grep -oP '"version"\s*:\s*"[0-9.]+"' | grep -oP '[0-9.]+' || echo "0.0.0"
}

# Compare versions (returns 0 if $1 > $2)
version_gt() {
    test "$(echo -e "$1\n$2" | sort -V | tail -1)" != "$2"
}

# Download and verify file
download_file() {
    local filename="$1"
    local admin_key

    # Read admin key from .env
    if [[ -f "$INSTALL_DIR/.env" ]]; then
        admin_key=$(grep -oP 'PDEV_ADMIN_KEY=\K.*' "$INSTALL_DIR/.env" 2>/dev/null || echo "")
    fi

    if [[ -z "$admin_key" ]]; then
        error "Admin key not found in .env"
        return 1
    fi

    local response
    response=$(curl -sf --connect-timeout 30 \
        -H "X-Admin-Key: $admin_key" \
        "$UPDATE_FILE_URL/$filename" 2>/dev/null) || {
        error "Failed to download $filename"
        return 1
    }

    # Verify response has content and hash
    local content hash
    content=$(echo "$response" | jq -r '.content' 2>/dev/null) || {
        error "Invalid response format for $filename"
        return 1
    }
    hash=$(echo "$response" | jq -r '.hash' 2>/dev/null) || true

    if [[ -z "$content" || "$content" == "null" ]]; then
        error "Empty content for $filename"
        return 1
    fi

    # Verify hash if provided
    if [[ -n "$hash" && "$hash" != "null" ]]; then
        local computed_hash
        computed_hash=$(echo -n "$content" | sha256sum | awk '{print $1}')
        if [[ "$computed_hash" != "$hash" ]]; then
            error "Hash mismatch for $filename"
            return 1
        fi
    fi

    echo "$content"
}

# Backup current files
backup_files() {
    local backup_dir="$INSTALL_DIR/backups/$(date '+%Y%m%d_%H%M%S')"
    mkdir -p "$backup_dir"

    [[ -f "$INSTALL_DIR/server.js" ]] && cp "$INSTALL_DIR/server.js" "$backup_dir/"

    log "Backed up to $backup_dir"
    echo "$backup_dir"
}

# Perform update
do_update() {
    log "Starting update..."

    # Backup current files
    local backup_dir
    backup_dir=$(backup_files)

    # Download new server.js
    local new_content
    new_content=$(download_file "server.js") || {
        error "Failed to download server.js"
        return 1
    }

    # Write new file
    echo "$new_content" | sudo tee "$INSTALL_DIR/server.js" > /dev/null

    # Verify syntax
    if ! node -c "$INSTALL_DIR/server.js" 2>/dev/null; then
        error "Syntax error in new server.js, rolling back"
        sudo cp "$backup_dir/server.js" "$INSTALL_DIR/server.js"
        return 1
    fi

    # Restart service
    log "Restarting PM2 service..."
    pm2 restart pdev-live --update-env || {
        error "Failed to restart service, rolling back"
        sudo cp "$backup_dir/server.js" "$INSTALL_DIR/server.js"
        pm2 restart pdev-live --update-env
        return 1
    }

    # Wait for health check
    sleep 5
    if curl -sf "http://localhost:${PORT:-3016}/health" > /dev/null 2>&1; then
        log "Update complete! New version: $(get_local_version)"
    else
        error "Health check failed after update, rolling back"
        sudo cp "$backup_dir/server.js" "$INSTALL_DIR/server.js"
        pm2 restart pdev-live --update-env
        return 1
    fi
}

# Main
main() {
    log "PDev Live Update Check"

    local local_version remote_version
    local_version=$(get_local_version)
    remote_version=$(get_remote_version) || exit 1

    log "Local version: $local_version"
    log "Remote version: $remote_version"

    if [[ "$FORCE_UPDATE" == "true" ]]; then
        log "Force update requested"
        if [[ "$CHECK_ONLY" == "true" ]]; then
            log "Would update (--check mode)"
        else
            do_update
        fi
    elif version_gt "$remote_version" "$local_version"; then
        log "Update available: $local_version -> $remote_version"
        if [[ "$CHECK_ONLY" == "true" ]]; then
            log "Update available (--check mode, not updating)"
        else
            do_update
        fi
    else
        log "Already up to date"
    fi
}

main
