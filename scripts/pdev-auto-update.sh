#!/bin/bash
# PDev Live Auto-Update Script
# Checks acme (master) for updates and applies them automatically
# Runs via cron every 5 minutes on satellite servers (rmlve, djm)

set -e

# Configuration (can be overridden via environment or config file)
CONFIG_FILE="${CONFIG_FILE:-/opt/services/pdev-live/.update-config}"
[ -f "$CONFIG_FILE" ] && source "$CONFIG_FILE"

MASTER_URL="${PDEV_MASTER_URL:-https://vyxenai.com/pdev/api}"
LOCAL_DIR="${PDEV_LOCAL_DIR:-/opt/services/pdev-live/server}"
FRONTEND_DIR="${PDEV_FRONTEND_DIR:-/opt/services/pdev-live/frontend}"
LOG_FILE="${PDEV_LOG_FILE:-/var/log/pdev-update.log}"
VERSION_FILE="$LOCAL_DIR/.version"
ADMIN_KEY_FILE="$LOCAL_DIR/.update-key"
PM2_NAME="${PDEV_PM2_NAME:-pdev-live}"

log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Ensure we have admin key
if [ ! -f "$ADMIN_KEY_FILE" ]; then
    log "ERROR: Update key not found at $ADMIN_KEY_FILE"
    exit 1
fi

ADMIN_KEY=$(cat "$ADMIN_KEY_FILE")

# Get current local version
LOCAL_VERSION="0.0.0"
if [ -f "$VERSION_FILE" ]; then
    LOCAL_VERSION=$(cat "$VERSION_FILE")
fi

# Check remote version
log "Checking for updates from $MASTER_URL..."
REMOTE_INFO=$(curl -s --connect-timeout 10 "$MASTER_URL/version" 2>/dev/null || echo '{"version":"error"}')
REMOTE_VERSION=$(echo "$REMOTE_INFO" | jq -r '.version // "error"' 2>/dev/null || echo "error")

if [ "$REMOTE_VERSION" = "error" ] || [ -z "$REMOTE_VERSION" ]; then
    log "ERROR: Could not fetch remote version"
    exit 1
fi

log "Local: $LOCAL_VERSION | Remote: $REMOTE_VERSION"

# Compare versions
if [ "$LOCAL_VERSION" = "$REMOTE_VERSION" ]; then
    log "Already up to date (v$LOCAL_VERSION)"
    exit 0
fi

log "Update available: $LOCAL_VERSION -> $REMOTE_VERSION"

# Extract file lists
SERVER_FILES=$(echo "$REMOTE_INFO" | jq -r '.serverFiles[]' 2>/dev/null)
FRONTEND_FILES=$(echo "$REMOTE_INFO" | jq -r '.frontendFiles[]' 2>/dev/null)

SERVER_UPDATED=0
FRONTEND_UPDATED=0

# Update server files
for FILE in $SERVER_FILES; do
    log "Fetching server/$FILE..."

    RESPONSE=$(curl -s --connect-timeout 30 \
        -H "X-Admin-Key: $ADMIN_KEY" \
        "$MASTER_URL/update-file/$FILE" 2>/dev/null)

    if echo "$RESPONSE" | jq -e '.error' &>/dev/null; then
        log "ERROR: Failed to fetch $FILE: $(echo "$RESPONSE" | jq -r '.error')"
        continue
    fi

    REMOTE_HASH=$(echo "$RESPONSE" | jq -r '.hash')
    echo "$RESPONSE" | jq -r '.content' > "/tmp/pdev-$FILE"

    # Verify hash
    LOCAL_HASH=$(sha256sum "/tmp/pdev-$FILE" | cut -d' ' -f1)
    if [ "$LOCAL_HASH" != "$REMOTE_HASH" ]; then
        log "WARNING: Hash mismatch for $FILE"
    fi

    # Backup and install
    [ -f "$LOCAL_DIR/$FILE" ] && cp "$LOCAL_DIR/$FILE" "$LOCAL_DIR/$FILE.bak"
    mv "/tmp/pdev-$FILE" "$LOCAL_DIR/$FILE"
    log "✓ Updated server/$FILE"
    SERVER_UPDATED=1
done

# Update frontend files
for FILE in $FRONTEND_FILES; do
    log "Fetching frontend/$FILE..."

    RESPONSE=$(curl -s --connect-timeout 30 \
        -H "X-Admin-Key: $ADMIN_KEY" \
        "$MASTER_URL/update-file/$FILE" 2>/dev/null)

    if echo "$RESPONSE" | jq -e '.error' &>/dev/null; then
        log "ERROR: Failed to fetch $FILE: $(echo "$RESPONSE" | jq -r '.error')"
        continue
    fi

    REMOTE_HASH=$(echo "$RESPONSE" | jq -r '.hash')
    echo "$RESPONSE" | jq -r '.content' > "/tmp/pdev-$FILE"

    # Verify hash
    LOCAL_HASH=$(sha256sum "/tmp/pdev-$FILE" | cut -d' ' -f1)
    if [ "$LOCAL_HASH" != "$REMOTE_HASH" ]; then
        log "WARNING: Hash mismatch for $FILE"
    fi

    # Backup and install
    [ -f "$FRONTEND_DIR/$FILE" ] && cp "$FRONTEND_DIR/$FILE" "$FRONTEND_DIR/$FILE.bak"
    mv "/tmp/pdev-$FILE" "$FRONTEND_DIR/$FILE"
    log "✓ Updated frontend/$FILE"
    FRONTEND_UPDATED=1
done

# Update version file
echo "$REMOTE_VERSION" > "$VERSION_FILE"

# Restart service if server files were updated
if [ $SERVER_UPDATED -eq 1 ]; then
    log "Restarting $PM2_NAME..."
    pm2 restart "$PM2_NAME" --update-env 2>&1 | tee -a "$LOG_FILE"
fi

log "✅ Update complete: v$REMOTE_VERSION (server: $SERVER_UPDATED, frontend: $FRONTEND_UPDATED)"
