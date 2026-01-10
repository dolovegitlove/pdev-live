#!/usr/bin/env bash
# Git-first deployment for PDev Live installer scripts
# Prevents: fixing installers locally but forgetting to deploy → installation failures
#
# Usage:
#   ./deploy-installer.sh              # Normal deploy (git checks enforced)
#   ./deploy-installer.sh --force      # Emergency deploy (logs bypass)
#   ./deploy-installer.sh --dry-run    # Preview what would be deployed
#   ./deploy-installer.sh --rollback pdl-installer.sh  # Restore previous version
#
# Agent Validation: world-class-code-enforcer (APPROVED)

set -euo pipefail

# Load configuration defaults
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(dirname "$SCRIPT_DIR")"
[ -f "$PROJECT_DIR/.pdev-defaults.sh" ] && source "$PROJECT_DIR/.pdev-defaults.sh"

# Configuration
REMOTE_HOST="${DEPLOY_USER:-acme}"
REMOTE_PATH="/var/www/vyxenai.com/pdev/install"
BACKUP_DIR="$REMOTE_PATH/.backups"
EXPECTED_BRANCH="main"
LOG_FILE="$PROJECT_DIR/.deploy-log"

# Files to deploy
INSTALLER_FILES=(
  "pdl-installer.sh"
  "partner-web-installer.sh"
)

# Colors
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

error() { echo -e "${RED}ERROR:${NC} $1" >&2; }
success() { echo -e "${GREEN}$1${NC}"; }
warn() { echo -e "${YELLOW}WARNING:${NC} $1"; }
die() { error "$1"; exit 1; }

# Cleanup temporary files on exit
cleanup() {
  if [[ "${REMOTE_HOST}" != "" ]]; then
    ssh "$REMOTE_HOST" "rm -f $REMOTE_PATH/.*.tmp" 2>/dev/null || true
  fi
}
trap cleanup EXIT

# Parse arguments
FORCE_MODE=false
DRY_RUN=false
ROLLBACK_FILE=""

while [[ $# -gt 0 ]]; do
  case $1 in
    --force)
      FORCE_MODE=true
      warn "FORCE MODE ENABLED - Git checks bypassed"
      echo "$(date -Iseconds) FORCE_DEPLOY_INSTALLER user=$(whoami) pwd=$(pwd)" >> "$LOG_FILE"
      shift
      ;;
    --dry-run)
      DRY_RUN=true
      shift
      ;;
    --rollback)
      ROLLBACK_FILE="$2"
      shift 2
      ;;
    *)
      die "Unknown option: $1"
      ;;
  esac
done

# Rollback function
rollback_file() {
  local file=$1
  local backup_file

  echo "Searching for latest backup of $file..."
  backup_file=$(ssh "$REMOTE_HOST" "ls -t $BACKUP_DIR/${file}.* 2>/dev/null | head -1" || echo "")

  if [[ -z "$backup_file" ]]; then
    die "No backup found for $file"
  fi

  echo "Found backup: $backup_file"
  read -p "Restore this backup? (y/n): " -n 1 -r
  echo
  if [[ $REPLY =~ ^[Yy]$ ]]; then
    ssh "$REMOTE_HOST" "cp '$backup_file' '$REMOTE_PATH/$file'" || die "Rollback failed"
    success "Rolled back $file to previous version"
    exit 0
  else
    echo "Rollback cancelled"
    exit 1
  fi
}

# Handle rollback mode
if [[ -n "$ROLLBACK_FILE" ]]; then
  rollback_file "$ROLLBACK_FILE"
fi

cd "$PROJECT_DIR"

# Dry-run mode
if [[ "$DRY_RUN" == "true" ]]; then
  echo -e "${YELLOW}[DRY RUN MODE]${NC}"
  echo ""
  echo "Would deploy the following files:"
  for file in "${INSTALLER_FILES[@]}"; do
    if [[ -f "installer/$file" ]]; then
      echo "  ✅ installer/$file → $REMOTE_HOST:$REMOTE_PATH/$file"
    else
      echo "  ❌ installer/$file (not found)"
    fi
  done
  echo ""
  echo "Target: $REMOTE_HOST:$REMOTE_PATH/"
  echo "Backups: $REMOTE_HOST:$BACKUP_DIR/"
  echo ""
  echo "Verification steps:"
  echo "  1. File existence (ssh)"
  echo "  2. Permissions check (755)"
  echo "  3. Syntax validation (bash -n)"
  echo "  4. HTTP accessibility (curl)"
  echo "  5. Checksum integrity (sha256sum)"
  echo ""
  exit 0
fi

# 0. Verify we're in a git repo
if ! git rev-parse --git-dir > /dev/null 2>&1; then
  die "Not a git repository: $PROJECT_DIR"
fi

# 1. Pre-deployment checks (skip in force mode)
if [[ "$FORCE_MODE" == false ]]; then
  echo "Running pre-deployment checks..."

  # Check current branch
  CURRENT_BRANCH=$(git branch --show-current)
  if [[ "$CURRENT_BRANCH" != "$EXPECTED_BRANCH" ]]; then
    die "Must be on '$EXPECTED_BRANCH' branch (currently on '$CURRENT_BRANCH')"
  fi

  # Check for uncommitted changes in installer files
  for file in "${INSTALLER_FILES[@]}"; do
    if ! git diff --quiet "installer/$file" 2>/dev/null; then
      die "Uncommitted changes in installer/$file"
    fi
    if ! git diff --cached --quiet "installer/$file" 2>/dev/null; then
      die "Staged but uncommitted changes in installer/$file"
    fi
  done

  # Check if local is ahead of remote
  git fetch origin "$EXPECTED_BRANCH" --quiet 2>/dev/null || die "Cannot fetch from origin"

  LOCAL=$(git rev-parse HEAD)
  REMOTE=$(git rev-parse "origin/$EXPECTED_BRANCH")

  if [[ "$LOCAL" != "$REMOTE" ]]; then
    if git merge-base --is-ancestor "$REMOTE" "$LOCAL"; then
      die "Local commits not pushed to origin"
    else
      die "Local is behind origin (pull required)"
    fi
  fi

  success "Git checks passed"
fi

# 2. Syntax validation (ALWAYS runs, even with --force)
echo "Validating syntax..."
for file in "${INSTALLER_FILES[@]}"; do
  if [[ -f "installer/$file" ]]; then
    if ! bash -n "installer/$file" 2>&1; then
      die "Syntax error in installer/$file"
    fi

    # Check for required safety patterns
    if ! grep -q "set -euo pipefail" "installer/$file"; then
      warn "installer/$file missing 'set -euo pipefail'"
    fi
  else
    warn "File not found: installer/$file (skipping)"
  fi
done
success "Syntax validation passed"

# 3. Confirm force mode
if [[ "$FORCE_MODE" == true ]]; then
  echo ""
  warn "You are about to deploy WITHOUT git verification."
  read -p "Type 'DEPLOY' to confirm: " CONFIRM
  if [[ "$CONFIRM" != "DEPLOY" ]]; then
    echo "Deployment cancelled."
    exit 1
  fi
  echo "$(date -Iseconds) FORCE_DEPLOY_INSTALLER_CONFIRMED" >> "$LOG_FILE"
fi

# 4. Deploy each installer file
TIMESTAMP=$(date +%Y%m%d_%H%M%S)
FAILED=()

deploy_file() {
  local file=$1
  local remote_file="$REMOTE_PATH/$file"
  local backup_file="$BACKUP_DIR/${file}.$TIMESTAMP"
  local temp_file="$REMOTE_PATH/.$file.tmp"

  echo ""
  echo "Deploying $file..."

  # Create backup directory
  ssh "$REMOTE_HOST" "mkdir -p $BACKUP_DIR" || die "Failed to create backup directory"

  # Backup existing file (if exists)
  ssh "$REMOTE_HOST" "test -f $remote_file && cp $remote_file $backup_file || true"

  # Upload to temp location
  if ! scp "installer/$file" "$REMOTE_HOST:$temp_file"; then
    error "SCP upload failed for $file"
    return 1
  fi

  # Validate uploaded file (syntax check on remote)
  if ! ssh "$REMOTE_HOST" "bash -n $temp_file" 2>/dev/null; then
    error "Remote syntax validation failed for $file"
    ssh "$REMOTE_HOST" "rm -f $temp_file"
    return 1
  fi

  # Set permissions
  ssh "$REMOTE_HOST" "chmod 755 $temp_file" || {
    error "Failed to set permissions for $file"
    ssh "$REMOTE_HOST" "rm -f $temp_file"
    return 1
  }

  # Atomic rename
  if ! ssh "$REMOTE_HOST" "mv $temp_file $remote_file"; then
    error "Failed to move $file into place - restoring backup"
    ssh "$REMOTE_HOST" "test -f $backup_file && cp $backup_file $remote_file || true"
    return 1
  fi

  # Verify deployment
  echo "  → Verifying deployment..."

  # Check 1: File exists
  if ! ssh "$REMOTE_HOST" "test -f $remote_file"; then
    error "Verification failed: file not found"
    ssh "$REMOTE_HOST" "cp $backup_file $remote_file"
    return 1
  fi

  # Check 2: Permissions
  PERMS=$(ssh "$REMOTE_HOST" "stat -c '%a' $remote_file" 2>/dev/null || echo "")
  if [[ "$PERMS" != "755" ]]; then
    error "Verification failed: incorrect permissions ($PERMS, expected 755)"
    ssh "$REMOTE_HOST" "cp $backup_file $remote_file"
    return 1
  fi

  # Check 3: HTTP accessibility
  if ! curl -f -s -o /dev/null "https://vyxenai.com/pdev/install/$file"; then
    warn "HTTP check failed (may be normal if nginx not configured)"
  fi

  # Check 4: Checksum integrity
  LOCAL_SHA=$(sha256sum "installer/$file" | awk '{print $1}')
  REMOTE_SHA=$(ssh "$REMOTE_HOST" "sha256sum $remote_file" | awk '{print $1}')
  if [[ "$LOCAL_SHA" != "$REMOTE_SHA" ]]; then
    error "Verification failed: checksum mismatch"
    ssh "$REMOTE_HOST" "cp $backup_file $remote_file"
    return 1
  fi

  # Cleanup old backups (keep last 5)
  ssh "$REMOTE_HOST" "ls -t $BACKUP_DIR/${file}.* 2>/dev/null | tail -n +6 | xargs -r rm" 2>/dev/null || true

  success "✅ Deployed: $file"
  return 0
}

# Deploy all files
for file in "${INSTALLER_FILES[@]}"; do
  if [[ -f "installer/$file" ]]; then
    if ! deploy_file "$file"; then
      FAILED+=("$file")
    fi
  else
    warn "Skipping $file (not found in installer/)"
  fi
done

# 5. Report results
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
if [[ ${#FAILED[@]} -gt 0 ]]; then
  error "Deployment failed for: ${FAILED[*]}"
  echo ""
  echo "Rollback with:"
  for file in "${FAILED[@]}"; do
    echo "  ./deploy-installer.sh --rollback $file"
  done
  exit 1
else
  success "All installers deployed successfully"
  echo ""
  echo "Deployed to: $REMOTE_HOST:$REMOTE_PATH/"
  echo "Access at: https://vyxenai.com/pdev/install/"
  echo ""

  # Log successful deploy
  echo "$(date -Iseconds) DEPLOY_INSTALLER_SUCCESS commit=$(git rev-parse --short HEAD 2>/dev/null || echo 'unknown') files=${INSTALLER_FILES[*]}" >> "$LOG_FILE"
fi
