#!/bin/bash
# PDev-Live Shell Script Defaults
# Source this file in deployment scripts to get configuration
# Can be overridden by .env or environment variables

# Load .env if present
if [ -f "$(dirname "$0")/.env" ]; then
  set -a
  source "$(dirname "$0")/.env"
  set +a
elif [ -f "$HOME/projects/pdev-live/.env" ]; then
  set -a
  source "$HOME/projects/pdev-live/.env"
  set +a
fi

# Partner identity defaults
export PARTNER_DOMAIN="${PARTNER_DOMAIN:-localhost}"
export PARTNER_SERVER_NAME="${PARTNER_SERVER_NAME:-default-server}"
export DEPLOY_USER="${DEPLOY_USER:-deploy}"

# Path defaults (use config or legacy paths)
export FRONTEND_DEPLOY_PATH="${FRONTEND_DEPLOY_PATH:-/var/www/\${PARTNER_DOMAIN}/pdev}"
export FRONTEND_BACKUP_PATH="${FRONTEND_BACKUP_PATH:-/var/www/\${PARTNER_DOMAIN}/pdev-backups}"
export BACKEND_SERVICE_PATH="${BACKEND_SERVICE_PATH:-/opt/services/pdev-live}"

# PM2 defaults
export PM2_APP_NAME="${PM2_APP_NAME:-pdev-live}"

# Expand variables in paths
FRONTEND_DEPLOY_PATH=$(eval echo "$FRONTEND_DEPLOY_PATH")
FRONTEND_BACKUP_PATH=$(eval echo "$FRONTEND_BACKUP_PATH")
