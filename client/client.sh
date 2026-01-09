#!/bin/bash
#
# PDev Live Client - CLI tool to post updates to PDev Live server
#
# Usage:
#   pdev-live start <command_type> <project_name>  - Start/resume session
#   pdev-live step <content>                        - Add step to current session
#   pdev-live doc <name> <path>                     - Push full document
#   pdev-live phase <phase_num> <phase_name>       - Start new phase
#   pdev-live end [status]                         - End session
#   pdev-live status                                - Show current session info
#   pdev-live list                                  - List active sessions
#   pdev-live use <project>                         - Switch to a different project session
#
# Session behavior:
#   - start: Resumes existing active session if one exists for project
#   - regen commands: Always create new session (overwrite behavior)
#   - PDEV_FORCE_NEW=1: Force new session even if one exists
#

# =============================================================================
# CONFIG FILE LOADING (SECURE)
# =============================================================================
# Load PDev Live URL from config file with security validation
# Precedence: 1) PDEV_LIVE_URL env var, 2) config file, 3) fail
load_pdev_config() {
  # Skip if already set via environment variable
  if [ -n "$PDEV_LIVE_URL" ]; then
    return 0
  fi

  # Config file locations (checked in order)
  local config_locations=(
    "$HOME/.pdev-live-config"
    "$HOME/.claude/tools/pdev-live/.config"
  )

  for config_file in "${config_locations[@]}"; do
    if [ ! -f "$config_file" ]; then
      continue
    fi

    # SECURITY: Check file permissions (must be 600 or 400)
    local perms
    if [[ "$OSTYPE" == "darwin"* ]]; then
      perms=$(stat -f "%OLp" "$config_file" 2>/dev/null)
    else
      perms=$(stat -c "%a" "$config_file" 2>/dev/null)
    fi

    if [ "$perms" != "600" ] && [ "$perms" != "400" ]; then
      echo "ERROR: Config file has insecure permissions: $config_file ($perms)" >&2
      echo "Fix with: chmod 600 $config_file" >&2
      exit 1
    fi

    # SECURITY: Parse manually (safer than sourcing)
    # Extract PDEV_LIVE_URL and PDEV_BASE_URL only
    while IFS='=' read -r key value; do
      # Skip comments and empty lines
      [[ -z "$key" || "$key" =~ ^[[:space:]]*# ]] && continue

      # Trim whitespace and quotes
      key=$(echo "$key" | xargs)
      value=$(echo "$value" | xargs | tr -d '"')

      # Only accept specific variables
      case "$key" in
        PDEV_LIVE_URL)
          export PDEV_LIVE_URL="$value"
          ;;
        PDEV_BASE_URL)
          export PDEV_BASE_URL="$value"
          ;;
        PDEV_TOKEN)
          export PDEV_TOKEN="$value"
          ;;
      esac
    done < "$config_file"

    # If config loaded successfully, return
    if [ -n "$PDEV_LIVE_URL" ]; then
      return 0
    fi
  done

  # No config found - fail with helpful error
  echo "ERROR: PDev Live URL not configured" >&2
  echo "" >&2
  echo "OPTIONS:" >&2
  echo "  1. Set environment variable:" >&2
  echo "     export PDEV_LIVE_URL=https://example.com/pdev/api" >&2
  echo "" >&2
  echo "  2. Create config file (~/.pdev-live-config):" >&2
  echo "     cat > ~/.pdev-live-config <<EOF" >&2
  echo "# PDev Live Client Configuration" >&2
  echo "PDEV_LIVE_URL=https://your-domain.com/pdev/api" >&2
  echo "PDEV_BASE_URL=https://your-domain.com/pdev" >&2
  echo "PDEV_TOKEN=your-server-token-here" >&2
  echo "EOF" >&2
  echo "     chmod 600 ~/.pdev-live-config" >&2
  echo "" >&2
  echo "  3. Run installer (creates config automatically):" >&2
  echo "     ~/projects/pdev-live/installer/pdl-installer.sh --domain example.com" >&2
  exit 1
}

detect_server() {
  if [ -n "$PDEV_SERVER" ]; then
    echo "$PDEV_SERVER"
    return
  fi

  # Load partner server name from config if available
  if [ -z "$PARTNER_SERVER_NAME" ] && [ -f "$HOME/projects/pdev-live/.env" ]; then
    PARTNER_SERVER_NAME=$(grep "^PARTNER_SERVER_NAME=" "$HOME/projects/pdev-live/.env" 2>/dev/null | cut -d= -f2 | tr -d '"' || echo "")
  fi

  HOSTNAME=$(hostname -s 2>/dev/null || hostname)
  case "$HOSTNAME" in
    *dolovdev*|Dolovs*|dolov-mac*|Dolov*|Mac) echo "dolovdev" ;;
    srv*|${PARTNER_SERVER_NAME}*) echo "${PARTNER_SERVER_NAME:-$(hostname -s)}" ;;
    itt|*ittz*) echo "ittz" ;;
    *dolov*) echo "dolov" ;;
    WIN*|DESKTOP*|*wdress*) echo "wdress" ;;
    wonderful-lehmann*|*djm*) echo "djm" ;;
    *rmlve*) echo "rmlve" ;;
    *cfree*) echo "cfree" ;;
    *) echo "${HOSTNAME%%.*}" ;;
  esac
}

# Load configuration (env var takes precedence, then config file)
load_pdev_config

# Validate URL format
if [[ ! "$PDEV_LIVE_URL" =~ ^https?:// ]]; then
  echo "ERROR: PDEV_LIVE_URL must start with http:// or https://" >&2
  echo "Current value: $PDEV_LIVE_URL" >&2
  exit 1
fi

# Derive base URL if not explicitly set (strip /api suffix)
if [ -z "$PDEV_BASE_URL" ]; then
  PDEV_BASE_URL="${PDEV_LIVE_URL%/api}"
fi

# Load token from file if not set via config/env
if [ -z "$PDEV_TOKEN" ]; then
  _token_file="$HOME/.claude/tools/pdev-live/token"
  if [ -f "$_token_file" ]; then
    PDEV_TOKEN=$(cat "$_token_file" 2>/dev/null | tr -d '\n')
  fi
  unset _token_file
fi

# Check for server token (required for API authentication)
if [ -z "$PDEV_TOKEN" ]; then
  echo "ERROR: PDEV_TOKEN not configured" >&2
  echo "" >&2
  echo "Token can be set via:" >&2
  echo "  1. Token file: ~/.claude/tools/pdev-live/token" >&2
  echo "  2. Config file: Add PDEV_TOKEN=... to ~/.pdev-live-config" >&2
  echo "" >&2
  echo "Get a token from your PDev Live admin." >&2
  exit 1
fi

# Build curl auth header
CURL_AUTH=(-H "X-Pdev-Token: $PDEV_TOKEN")

# Detect current server hostname for session tracking
PDEV_SERVER=$(detect_server)

SESSIONS_DIR="/tmp/pdev-live-sessions"
mkdir -p "$SESSIONS_DIR"

# Get current project from PDEV_PROJECT env var or default session
get_current_project() {
  if [ -n "$PDEV_PROJECT" ]; then
    echo "$PDEV_PROJECT"
  elif [ -f "$SESSIONS_DIR/default-$PDEV_SERVER.txt" ]; then
    cat "$SESSIONS_DIR/default-$PDEV_SERVER.txt"
  fi
}

# Session file paths (project-based for multi-session support)
get_session_file() {
  local project="${1:-$(get_current_project)}"
  if [ -n "$project" ]; then
    echo "$SESSIONS_DIR/$PDEV_SERVER-$project.json"
  else
    echo "$SESSIONS_DIR/$PDEV_SERVER-default.json"
  fi
}

get_phase_file() {
  local project="${1:-$(get_current_project)}"
  if [ -n "$project" ]; then
    echo "$SESSIONS_DIR/$PDEV_SERVER-$project-phase.json"
  else
    echo "$SESSIONS_DIR/$PDEV_SERVER-default-phase.json"
  fi
}

RED='\033[0;31m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
YELLOW='\033[0;33m'
NC='\033[0m'

log() { echo -e "${BLUE}[PDev Live]${NC} $1" >&2; }
error() { echo -e "${RED}[PDev Live Error]${NC} $1" >&2; }
success() { echo -e "${GREEN}[PDev Live]${NC} $1" >&2; }
warn() { echo -e "${YELLOW}[PDev Live]${NC} $1" >&2; }

get_session_id() {
  local sf=$(get_session_file)
  local sid=""
  if [ -f "$sf" ]; then
    sid=$(jq -r '.sessionId // empty' "$sf" 2>/dev/null)
  fi

  # Validate session exists and is not deleted (CLI expects accurate state)
  if [ -n "$sid" ] && [ "$sid" != "null" ]; then
    local validation=$(curl -s --connect-timeout 3 --max-time 5 \
      "$PDEV_LIVE_URL/sessions/$sid" 2>/dev/null)

    if echo "$validation" | jq -e '.error' >/dev/null 2>&1; then
      # Session deleted - clear cache and return empty
      rm -f "$sf" 2>/dev/null
      rm -f "/tmp/pdev-live-valid-$sid" 2>/dev/null
      echo ""
      return
    fi
  fi

  echo "$sid"
}

# Check if command should force new session (regen commands)
should_force_new() {
  local cmd="$1"
  # regen commands always create new sessions
  case "$cmd" in
    regen*|*-regen) return 0 ;;
  esac
  # Explicit force via env var
  [ "$PDEV_FORCE_NEW" = "1" ] && return 0
  return 1
}

# ============================================================================
# PROJECT REGISTRY FUNCTIONS (for remote doc fetching)
# ============================================================================

PROJECTS_FILE="${PROJECTS_FILE:-$HOME/.claude/tools/pdev-live/projects.json}"

# Sanitize path for SSH (prevent injection)
sanitize_remote_path() {
  local path="$1"
  if [[ "$path" =~ ^[a-zA-Z0-9/_.-]+$ ]]; then
    echo "$path"
    return 0
  fi
  error "Invalid path characters: $path"
  return 1
}

# Resolve project name to server/path via registry
resolve_project() {
  local project_name="$1"

  if [ -z "$project_name" ]; then
    return 1
  fi

  if [ ! -f "$PROJECTS_FILE" ]; then
    return 1
  fi

  # Validate JSON
  if ! jq empty "$PROJECTS_FILE" 2>/dev/null; then
    error "Invalid projects.json"
    return 1
  fi

  # Direct match (case-insensitive) - use -c for compact single-line output
  local lower_name=$(echo "$project_name" | tr '[:upper:]' '[:lower:]')
  local match=$(jq -c --arg p "$lower_name" \
    '.projects | to_entries[] |
     select(.key | ascii_downcase == $p) |
     .value' "$PROJECTS_FILE" 2>/dev/null | head -1)

  if [ -n "$match" ] && [ "$match" != "null" ]; then
    echo "$match"
    return 0
  fi

  # Alias search - use -c for compact single-line output
  match=$(jq -c --arg p "$lower_name" \
    '.projects | to_entries[] |
     select(.value.aliases | map(ascii_downcase) | index($p)) |
     .value' "$PROJECTS_FILE" 2>/dev/null | head -1)

  if [ -n "$match" ] && [ "$match" != "null" ]; then
    echo "$match"
    return 0
  fi

  return 1
}

# Fetch docs from remote server via SSH and push to pdev-live API
fetch_remote_docs() {
  local server="$1"
  local remote_path="$2"
  local session_id="$3"
  local quiet="$4"

  # Validate inputs
  if [ -z "$server" ] || [ -z "$remote_path" ]; then
    error "fetch_remote_docs: server and path required"
    return 1
  fi

  # Validate server name format
  if ! [[ "$server" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    error "Invalid server name: $server"
    return 1
  fi

  # Sanitize path
  local safe_path
  safe_path=$(sanitize_remote_path "$remote_path") || return 1

  [ -z "$quiet" ] && log "Fetching docs from $server:$safe_path"

  # Get list of doc files
  local doc_files
  doc_files=$(ssh -o ConnectTimeout=10 -o BatchMode=yes "$server" \
    "find \"$safe_path\" -maxdepth 1 -name '*.md' -type f 2>/dev/null" 2>&1)

  if [ $? -ne 0 ] || [ -z "$doc_files" ]; then
    [ -z "$quiet" ] && warn "No docs found at $server:$safe_path"
    return 1
  fi

  local count=0
  local DOC_LIST=""

  while IFS= read -r remote_file; do
    [ -z "$remote_file" ] && continue

    local basename=$(basename "$remote_file")
    local content
    # Use -n to prevent SSH from consuming stdin (which breaks the while loop)
    content=$(ssh -n -o ConnectTimeout=30 -o BatchMode=yes "$server" \
      "cat \"$remote_file\"" 2>/dev/null)

    if [ -n "$content" ]; then
      # Get phase info
      local PHASE_INFO=$(get_phase_for_doc "$basename")
      local PHASE_NUM=$(echo "$PHASE_INFO" | cut -d'|' -f1)
      local PHASE_NAME=$(echo "$PHASE_INFO" | cut -d'|' -f2)

      # Get version from content
      local VERSION=$(echo "$content" | grep -m1 'pdev_version:' | sed 's/.*pdev_version:[[:space:]]*//' | tr -d '\r')

      # Push to pdev-live API
      curl -s "${CURL_AUTH[@]}" -X POST "$PDEV_LIVE_URL/sessions/$session_id/steps" \
        -H "Content-Type: application/json" \
        -d "{
          \"type\": \"document\",
          \"documentName\": $(echo "$basename" | jq -Rs '.'),
          \"documentPath\": $(echo "$remote_file" | jq -Rs '.'),
          \"content\": $(echo "$content" | jq -Rs '.'),
          \"phaseNumber\": ${PHASE_NUM:-0},
          \"phaseName\": $(echo "$PHASE_NAME" | jq -Rs '.')
        }" >/dev/null 2>&1

      DOC_LIST="${DOC_LIST}   • ${basename}${VERSION:+ (v$VERSION)}\n"
      count=$((count + 1))
    fi
  done <<< "$doc_files"

  if [ $count -gt 0 ]; then
    if [ -z "$quiet" ]; then
      success "Fetched $count docs from $server:"
      echo -e "$DOC_LIST"
    else
      log "Auto-fetched $count docs from $server"
    fi
  fi

  return 0
}

# Find existing active session on server
find_active_session() {
  local project="$1"
  curl -s "${CURL_AUTH[@]}" "$PDEV_LIVE_URL/sessions/find-active?server=$PDEV_SERVER&project=$project" 2>/dev/null
}

cmd_start() {
  local COMMAND_TYPE="${1:-unknown}"
  local PROJECT_NAME="${2:-$(basename "$PWD")}"

  # Resolve project from registry (if exists)
  local PROJECT_INFO=$(resolve_project "$PROJECT_NAME")
  local REMOTE_SERVER=""
  local REMOTE_PATH=""

  if [ -n "$PROJECT_INFO" ]; then
    REMOTE_SERVER=$(echo "$PROJECT_INFO" | jq -r '.server // empty')
    REMOTE_PATH=$(echo "$PROJECT_INFO" | jq -r '.path // empty')

    if [ -n "$REMOTE_SERVER" ]; then
      # Override PDEV_SERVER with resolved server for this session
      PDEV_SERVER="$REMOTE_SERVER"
      log "Resolved $PROJECT_NAME -> $REMOTE_SERVER:$REMOTE_PATH"
    fi
  fi

  # Check if we should force new session
  if ! should_force_new "$COMMAND_TYPE"; then
    # Try to find existing active session
    local EXISTING=$(find_active_session "$PROJECT_NAME")
    local FOUND=$(echo "$EXISTING" | jq -r '.found // false' 2>/dev/null)
    
    if [ "$FOUND" = "true" ]; then
      local EXISTING_ID=$(echo "$EXISTING" | jq -r '.session.id' 2>/dev/null)
      local EXISTING_CMD=$(echo "$EXISTING" | jq -r '.session.command_type' 2>/dev/null)
      local STEP_COUNT=$(echo "$EXISTING" | jq -r '.session.step_count // 0' 2>/dev/null)

      # Only resume if command type matches OR command is generic continuation
      if [ "$EXISTING_CMD" != "$COMMAND_TYPE" ] && [ "$COMMAND_TYPE" != "continue" ] && [ "$COMMAND_TYPE" != "resume" ]; then
        log "Different command type ($COMMAND_TYPE vs $EXISTING_CMD) - creating new session"
        # End the existing session first
        curl -s "${CURL_AUTH[@]}" -X POST "$PDEV_LIVE_URL/sessions/$EXISTING_ID/complete" \
          -H "Content-Type: application/json" \
          -d '{"status": "completed"}' >/dev/null 2>&1
        # Fall through to create new session (don't return)
      else
        log "Resuming existing session: /$EXISTING_CMD for $PROJECT_NAME"

        # Update local session file
        local sf=$(get_session_file "$PROJECT_NAME")
        local pf=$(get_phase_file "$PROJECT_NAME")
        echo "{\"sessionId\": \"$EXISTING_ID\", \"stepCount\": $STEP_COUNT, \"server\": \"$PDEV_SERVER\", \"project\": \"$PROJECT_NAME\", \"command\": \"$EXISTING_CMD\"}" > "$sf"

        # Create phase file if missing
        [ ! -f "$pf" ] && echo "{\"phaseNum\": 0, \"phaseName\": \"\"}" > "$pf"

        # Set as default project
        echo "$PROJECT_NAME" > "$SESSIONS_DIR/default-$PDEV_SERVER.txt"

        success "Resumed session: $EXISTING_ID ($STEP_COUNT steps)"
        echo "View at: $PDEV_BASE_URL/live/session.html?id=$EXISTING_ID"
        echo "Dashboard: $PDEV_BASE_URL/live/project.html?project=$PROJECT_NAME&server=$PDEV_SERVER"

        # Auto-seed existing docs on resume (only if session has 0 steps)
        if [ "$STEP_COUNT" = "0" ]; then
          if [ -n "$REMOTE_SERVER" ] && [ -n "$REMOTE_PATH" ]; then
            # Fetch from remote server
            fetch_remote_docs "$REMOTE_SERVER" "$REMOTE_PATH" "$EXISTING_ID" "quiet"
          else
            # Fallback to local
            cmd_seed "$PWD/docs" "quiet" 2>/dev/null || cmd_seed "$PWD" "quiet" 2>/dev/null
          fi
        fi

        echo "$EXISTING_ID"
        return 0
      fi
    fi
  fi

  # Create new session
  log "Creating new session: /$COMMAND_TYPE for $PROJECT_NAME on $PDEV_SERVER"

  RESPONSE=$(curl -s "${CURL_AUTH[@]}" -X POST "$PDEV_LIVE_URL/sessions" \
    -H "Content-Type: application/json" \
    -d "{
      \"server\": \"$PDEV_SERVER\",
      \"hostname\": \"$(hostname)\",
      \"project\": \"$PROJECT_NAME\",
      \"projectPath\": \"$PWD\",
      \"cwd\": \"$PWD\",
      \"commandType\": \"$COMMAND_TYPE\"
    }" 2>/dev/null)

  SESSION_ID=$(echo "$RESPONSE" | jq -r '.sessionId // empty' 2>/dev/null)

  if [ -n "$SESSION_ID" ] && [ "$SESSION_ID" != "null" ]; then
    local sf=$(get_session_file "$PROJECT_NAME")
    local pf=$(get_phase_file "$PROJECT_NAME")
    echo "{\"sessionId\": \"$SESSION_ID\", \"stepCount\": 0, \"server\": \"$PDEV_SERVER\", \"project\": \"$PROJECT_NAME\", \"command\": \"$COMMAND_TYPE\", \"remotePath\": \"$REMOTE_PATH\"}" > "$sf"
    echo "{\"phaseNum\": 0, \"phaseName\": \"\"}" > "$pf"
    # Set as default project for this server
    echo "$PROJECT_NAME" > "$SESSIONS_DIR/default-$PDEV_SERVER.txt"
    success "Session created: $SESSION_ID"
    echo "View at: $PDEV_BASE_URL/live/session.html?id=$SESSION_ID"
    echo "Dashboard: $PDEV_BASE_URL/live/project.html?project=$PROJECT_NAME&server=$PDEV_SERVER"

    # Auto-seed existing docs on new session
    if [ -n "$REMOTE_SERVER" ] && [ -n "$REMOTE_PATH" ]; then
      # Fetch from remote server
      fetch_remote_docs "$REMOTE_SERVER" "$REMOTE_PATH" "$SESSION_ID" "quiet"
    else
      # Fallback to local
      cmd_seed "$PWD/docs" "quiet" 2>/dev/null || cmd_seed "$PWD" "quiet" 2>/dev/null
    fi

    echo "$SESSION_ID"
  else
    error "Failed to create session: $RESPONSE"
    return 1
  fi
}

cmd_step() {
  local CONTENT="$*"
  local SESSION_ID=$(get_session_id)

  if [ -z "$SESSION_ID" ]; then
    error "No active session. Use: pdev-live start <command> <project>"
    return 1
  fi

  local pf=$(get_phase_file)
  local PHASE_NUM=""
  local PHASE_NAME=""
  if [ -f "$pf" ]; then
    PHASE_NUM=$(jq -r '.phaseNum // empty' "$pf" 2>/dev/null)
    PHASE_NAME=$(jq -r '.phaseName // empty' "$pf" 2>/dev/null)
  fi

  RESPONSE=$(curl -s "${CURL_AUTH[@]}" -X POST "$PDEV_LIVE_URL/sessions/$SESSION_ID/steps" \
    -H "Content-Type: application/json" \
    -d "{
      \"type\": \"output\",
      \"content\": $(echo "$CONTENT" | jq -Rs '.'),
      \"phaseNumber\": ${PHASE_NUM:-0},
      \"phaseName\": $(echo "$PHASE_NAME" | jq -Rs '.')
    }" 2>/dev/null)

  STEP_NUM=$(echo "$RESPONSE" | jq -r '.stepNumber // empty' 2>/dev/null)
  if [ -n "$STEP_NUM" ]; then
    local sf=$(get_session_file)
    if [ -f "$sf" ]; then
      local CURRENT=$(cat "$sf")
      echo "$CURRENT" | jq ".stepCount = $STEP_NUM" > "$sf"
    fi
    log "Step #$STEP_NUM added"
  fi
}

# Map document name to phase number and name
get_phase_for_doc() {
  local doc_name="$1"
  case "$doc_name" in
    *IDEATION*) echo "1|Idea - Project Definition" ;;
    *BENCHMARK*) echo "2|Benchmark - Competitive Analysis" ;;
    *GAP_ANALYSIS*|*GAP*) echo "3|Gap Analysis" ;;
    *INNOVATION*|*INNOV*) echo "4|Innovation Analysis" ;;
    *CAPABILITIES*|*CAPS*) echo "5|Capabilities Assessment" ;;
    *PRODUCT_SPEC*|*SPEC*) echo "6|Product Spec" ;;
    *DESIGN_SYSTEM*|*DESIGN*) echo "7|Design System" ;;
    *DEVELOPMENT_SOP*|*SOP*) echo "8|Development SOP" ;;
    *PIPELINE_VALIDATION*|*PV*) echo "9|Pipeline Validation" ;;
    *EVALUATION*|*EVAL*) echo "10|Evaluation" ;;
    *) echo "0|" ;;
  esac
}

cmd_doc() {
  local DOC_NAME="$1"
  local DOC_PATH="$2"
  local SESSION_ID=$(get_session_id)

  if [ -z "$SESSION_ID" ]; then
    error "No active session"
    return 1
  fi

  if [ -z "$DOC_PATH" ]; then
    error "Usage: pdev-live doc <name> <path>"
    return 1
  fi

  local CONTENT=""
  local IS_REMOTE=false

  # Check if path is remote (server:path format or /home/* on different server)
  if [[ "$DOC_PATH" == *:* ]]; then
    # Explicit server:path format
    IS_REMOTE=true
    local REMOTE_SERVER="${DOC_PATH%%:*}"
    local REMOTE_FILE="${DOC_PATH#*:}"
    log "Fetching from remote: $REMOTE_SERVER:$REMOTE_FILE"
    CONTENT=$(ssh -n -o ConnectTimeout=30 -o BatchMode=yes "$REMOTE_SERVER" "cat \"$REMOTE_FILE\"" 2>/dev/null)
    if [ -z "$CONTENT" ]; then
      error "Failed to fetch remote file: $DOC_PATH"
      return 1
    fi
  elif [[ "$DOC_PATH" == /home/* ]]; then
    # Remote path on session's server
    local sf=$(get_session_file)
    local REMOTE_SERVER=$(jq -r '.server // empty' "$sf" 2>/dev/null)
    if [ -n "$REMOTE_SERVER" ] && [ "$REMOTE_SERVER" != "dolovdev" ]; then
      IS_REMOTE=true
      log "Fetching from $REMOTE_SERVER:$DOC_PATH"
      CONTENT=$(ssh -n -o ConnectTimeout=30 -o BatchMode=yes "$REMOTE_SERVER" "cat \"$DOC_PATH\"" 2>/dev/null)
      if [ -z "$CONTENT" ]; then
        error "Failed to fetch remote file: $REMOTE_SERVER:$DOC_PATH"
        return 1
      fi
    fi
  fi

  # Fallback to local file if not remote
  if [ "$IS_REMOTE" = false ]; then
    if [ ! -f "$DOC_PATH" ]; then
      error "File not found: $DOC_PATH"
      return 1
    fi
    CONTENT=$(cat "$DOC_PATH")
  fi

  if [ -z "$CONTENT" ]; then
    error "Empty content from: $DOC_PATH"
    return 1
  fi

  local CONTENT=$(echo "$CONTENT")
  local CONTENT_SIZE=$(echo "$CONTENT" | wc -c | tr -d ' ')

  log "Pushing document: $DOC_NAME ($CONTENT_SIZE bytes)"

  # Auto-detect phase from document name
  local PHASE_INFO=$(get_phase_for_doc "$DOC_NAME")
  local PHASE_NUM=$(echo "$PHASE_INFO" | cut -d'|' -f1)
  local PHASE_NAME=$(echo "$PHASE_INFO" | cut -d'|' -f2)

  # Fallback to stored phase if not auto-detected
  if [ "$PHASE_NUM" = "0" ] || [ -z "$PHASE_NAME" ]; then
    local pf=$(get_phase_file)
    if [ -f "$pf" ]; then
      PHASE_NUM=$(jq -r '.phaseNum // 0' "$pf" 2>/dev/null)
      PHASE_NAME=$(jq -r '.phaseName // ""' "$pf" 2>/dev/null)
    fi
  fi

  RESPONSE=$(curl -s "${CURL_AUTH[@]}" -X POST "$PDEV_LIVE_URL/sessions/$SESSION_ID/steps" \
    -H "Content-Type: application/json" \
    -d "{
      \"type\": \"document\",
      \"documentName\": $(echo "$DOC_NAME" | jq -Rs '.'),
      \"documentPath\": $(echo "$DOC_PATH" | jq -Rs '.'),
      \"content\": $(echo "$CONTENT" | jq -Rs '.'),
      \"phaseNumber\": ${PHASE_NUM:-0},
      \"phaseName\": $(echo "$PHASE_NAME" | jq -Rs '.')
    }" 2>/dev/null)

  STEP_NUM=$(echo "$RESPONSE" | jq -r '.stepNumber // empty' 2>/dev/null)
  if [ -n "$STEP_NUM" ]; then
    success "Document #$STEP_NUM added: $DOC_NAME"
  else
    error "Failed to push document: $RESPONSE"
  fi
}

cmd_phase() {
  local PHASE_NUM="$1"
  local PHASE_NAME="${*:2}"

  if [ -z "$PHASE_NUM" ]; then
    error "Usage: pdev-live phase <num> <name>"
    return 1
  fi

  local pf=$(get_phase_file)
  echo "{\"phaseNum\": $PHASE_NUM, \"phaseName\": \"$PHASE_NAME\"}" > "$pf"
  log "Phase $PHASE_NUM: $PHASE_NAME"

  local SESSION_ID=$(get_session_id)
  if [ -n "$SESSION_ID" ]; then
    curl -s "${CURL_AUTH[@]}" -X POST "$PDEV_LIVE_URL/sessions/$SESSION_ID/steps" \
      -H "Content-Type: application/json" \
      -d "{
        \"type\": \"system\",
        \"content\": \"## Phase $PHASE_NUM: $PHASE_NAME\",
        \"phaseNumber\": $PHASE_NUM,
        \"phaseName\": $(echo "$PHASE_NAME" | jq -Rs '.')
      }" >/dev/null 2>&1
  fi
}

cmd_end() {
  local STATUS="${1:-completed}"
  local SESSION_ID=$(get_session_id)

  if [ -z "$SESSION_ID" ]; then
    error "No active session"
    return 1
  fi

  curl -s "${CURL_AUTH[@]}" -X POST "$PDEV_LIVE_URL/sessions/$SESSION_ID/complete" \
    -H "Content-Type: application/json" \
    -d "{\"status\": \"$STATUS\"}" >/dev/null 2>&1

  success "Session ended: $STATUS"
  rm -f "$(get_session_file)" "$(get_phase_file)"
}

cmd_status() {
  local sf=$(get_session_file)
  if [ -f "$sf" ]; then
    local project=$(get_current_project)
    echo "Active session for: $project"
    cat "$sf" | jq .
    echo ""
    echo "View at: $PDEV_BASE_URL/live/session.html?id=$(get_session_id)"
  else
    echo "No active session on $PDEV_SERVER"
    local sessions=$(ls -1 "$SESSIONS_DIR"/$PDEV_SERVER-*.json 2>/dev/null | grep -v phase)
    if [ -n "$sessions" ]; then
      echo ""
      echo "Other active sessions:"
      for s in $sessions; do
        local proj=$(jq -r '.project // "unknown"' "$s" 2>/dev/null)
        local sid=$(jq -r '.sessionId // "?"' "$s" 2>/dev/null)
        echo "  - $proj: $sid"
      done
      echo ""
      echo "Use: pdev-live use <project> to switch"
    fi
  fi
}

cmd_list() {
  echo "Active PDev Live sessions on $PDEV_SERVER:"
  echo ""
  local sessions=$(ls -1 "$SESSIONS_DIR"/$PDEV_SERVER-*.json 2>/dev/null | grep -v phase)
  if [ -z "$sessions" ]; then
    echo "  (none)"
    return
  fi

  local default_proj=$(get_current_project)
  for s in $sessions; do
    local proj=$(jq -r '.project // "unknown"' "$s" 2>/dev/null)
    local sid=$(jq -r '.sessionId // "?"' "$s" 2>/dev/null)
    local steps=$(jq -r '.stepCount // 0' "$s" 2>/dev/null)
    local cmd=$(jq -r '.command // "?"' "$s" 2>/dev/null)
    if [ "$proj" = "$default_proj" ]; then
      echo -e "  ${GREEN}* $proj${NC} ($cmd) - $steps steps - $sid"
    else
      echo "    $proj ($cmd) - $steps steps - $sid"
    fi
  done
  echo ""
  echo "Use: PDEV_PROJECT=<name> pdev-live step '...' to target specific project"
  echo "Or:  pdev-live use <project> to set default"
}

cmd_use() {
  local PROJECT="$1"
  if [ -z "$PROJECT" ]; then
    error "Usage: pdev-live use <project>"
    return 1
  fi

  local sf=$(get_session_file "$PROJECT")
  if [ ! -f "$sf" ]; then
    error "No active session for project: $PROJECT"
    echo "Active sessions:"
    cmd_list
    return 1
  fi

  echo "$PROJECT" > "$SESSIONS_DIR/default-$PDEV_SERVER.txt"
  success "Switched to: $PROJECT"
  cmd_status
}

# Set or update project manifest
cmd_manifest() {
  local DOCS_PATH="$1"
  local PROJECT=$(get_current_project)

  if [ -z "$PROJECT" ]; then
    PROJECT=$(basename "$PWD")
  fi

  if [ -z "$DOCS_PATH" ]; then
    DOCS_PATH="$PWD/docs"
  fi

  log "Setting manifest for $PDEV_SERVER/$PROJECT -> $DOCS_PATH"

  RESPONSE=$(curl -s "${CURL_AUTH[@]}" -X PUT "$PDEV_LIVE_URL/manifests/$PDEV_SERVER/$PROJECT" \
    -H "Content-Type: application/json" \
    -d "{\"docsPath\": \"$DOCS_PATH\"}" 2>/dev/null)

  if echo "$RESPONSE" | jq -e '.id' >/dev/null 2>&1; then
    success "Manifest registered for $PDEV_SERVER/$PROJECT"
    echo "$RESPONSE" | jq .
  else
    error "Failed to set manifest: $RESPONSE"
    return 1
  fi
}

# Register a specific doc in the manifest
cmd_manifest_doc() {
  local DOC_TYPE="$1"
  local FILE_NAME="$2"
  local PROJECT=$(get_current_project)

  if [ -z "$PROJECT" ]; then
    PROJECT=$(basename "$PWD")
  fi

  if [ -z "$DOC_TYPE" ] || [ -z "$FILE_NAME" ]; then
    error "Usage: pdev-live manifest-doc <type> <filename>"
    echo "Types: ideation, spec, sop, benchmark, design, gap, innov, caps"
    return 1
  fi

  RESPONSE=$(curl -s "${CURL_AUTH[@]}" -X PATCH "$PDEV_LIVE_URL/manifests/$PDEV_SERVER/$PROJECT/doc" \
    -H "Content-Type: application/json" \
    -d "{\"docType\": \"$DOC_TYPE\", \"fileName\": \"$FILE_NAME\"}" 2>/dev/null)

  if echo "$RESPONSE" | jq -e '.id' >/dev/null 2>&1; then
    success "Registered $DOC_TYPE -> $FILE_NAME"
  else
    error "Failed: $RESPONSE"
  fi
}

# Get manifest for current project
cmd_manifest_get() {
  local PROJECT=$(get_current_project)
  if [ -z "$PROJECT" ]; then
    PROJECT=$(basename "$PWD")
  fi

  RESPONSE=$(curl -s "${CURL_AUTH[@]}" "$PDEV_LIVE_URL/manifests/$PDEV_SERVER/$PROJECT" 2>/dev/null)

  if echo "$RESPONSE" | jq -e '.error' >/dev/null 2>&1; then
    warn "No manifest found for $PDEV_SERVER/$PROJECT"
  else
    echo "$RESPONSE" | jq .
  fi
}

cmd_share() {
  local HOURS="${1:-24}"
  local EMAIL="${2:-}"

  # Validate HOURS is a positive integer (max 30 days)
  if ! [[ "$HOURS" =~ ^[0-9]+$ ]] || [ "$HOURS" -lt 1 ] || [ "$HOURS" -gt 720 ]; then
    error "HOURS must be a positive integer between 1 and 720"
    return 1
  fi

  # Validate PDEV_LIVE_URL uses HTTPS
  if [[ ! "$PDEV_LIVE_URL" =~ ^https:// ]]; then
    error "PDEV_LIVE_URL must use HTTPS"
    return 1
  fi

  # Get and validate session ID
  local SESSION_ID=$(get_session_id)
  if [ -z "$SESSION_ID" ]; then
    error "No active session. Use: pdev-live start <command> <project>"
    return 1
  fi
  if ! [[ "$SESSION_ID" =~ ^[a-zA-Z0-9_-]+$ ]]; then
    error "Invalid session ID format"
    return 1
  fi

  # Validate email format if provided
  if [ -n "$EMAIL" ] && ! [[ "$EMAIL" =~ ^[^@]+@[^@]+\.[^@]+$ ]]; then
    error "Invalid email format"
    return 1
  fi

  # Get admin key
  local ADMIN_KEY="${PDEV_ADMIN_KEY:-}"
  if [ -z "$ADMIN_KEY" ]; then
    if [ -f "$HOME/.pdev-admin-key" ]; then
      local PERMS=$(stat -f "%OLp" "$HOME/.pdev-admin-key" 2>/dev/null || stat -c "%a" "$HOME/.pdev-admin-key" 2>/dev/null)
      if [ "$PERMS" != "600" ] && [ "$PERMS" != "400" ]; then
        error "~/.pdev-admin-key has insecure permissions ($PERMS). Run: chmod 600 ~/.pdev-admin-key"
        return 1
      fi
      ADMIN_KEY=$(cat "$HOME/.pdev-admin-key")
    else
      error "PDEV_ADMIN_KEY not set. Create ~/.pdev-admin-key (chmod 600) or export PDEV_ADMIN_KEY"
      return 1
    fi
  fi

  log "Creating guest link (expires in ${HOURS}h)..."

  # Build JSON safely using jq
  local JSON_PAYLOAD=$(jq -n \
    --arg sid "$SESSION_ID" \
    --argjson hours "$HOURS" \
    '{sessionId: $sid, expiresInHours: $hours}')

  # Use temp file for admin key header (prevents exposure in ps)
  local HEADER_FILE=$(mktemp)
  chmod 600 "$HEADER_FILE"
  printf "X-Admin-Key: %s" "$ADMIN_KEY" > "$HEADER_FILE"
  trap "rm -f \"$HEADER_FILE\"" RETURN

  local RESPONSE=$(curl -s "${CURL_AUTH[@]}" --max-time 30 -X POST "$PDEV_LIVE_URL/guest-links" \
    -H "Content-Type: application/json" \
    -H @"$HEADER_FILE" \
    -d "$JSON_PAYLOAD" 2>/dev/null)

  rm -f "$HEADER_FILE"

  if echo "$RESPONSE" | jq -e '.url' >/dev/null 2>&1; then
    local URL=$(echo "$RESPONSE" | jq -r '.url')
    local EXPIRES=$(echo "$RESPONSE" | jq -r '.expiresAt')
    local PROJECT=$(get_current_project)

    success "Guest link created!"
    echo ""
    echo "Share this link with your client:"
    echo -e "${GREEN}$URL${NC}"
    echo ""
    echo "Expires: $EXPIRES"

    # Send email if address provided
    if [ -n "$EMAIL" ]; then
      log "Sending link to $EMAIL..."
      local SUBJECT="PDev Live Session: $PROJECT"
      local BODY="You've been invited to view a PDev Live session.

Project: $PROJECT
Link: $URL

This link expires: $EXPIRES

--
PDev Suite"

      echo "$BODY" | mail -s "$SUBJECT" "$EMAIL" 2>/dev/null && \
        success "Email sent to $EMAIL" || \
        warn "Failed to send email (mail command not available)"
    fi
  else
    local ERR=$(echo "$RESPONSE" | jq -r '.error // "Unknown error"')
    error "Failed to create guest link: $ERR"
    return 1
  fi
}

# Get doc version and date info
get_doc_info() {
  local DOC_FILE="$1"
  local VERSION=$(grep -m1 'pdev_version:' "$DOC_FILE" 2>/dev/null | sed 's/.*pdev_version:[[:space:]]*//' | tr -d '\r')
  local MTIME=$(stat -f "%Sm" -t "%b %d" "$DOC_FILE" 2>/dev/null || stat -c "%y" "$DOC_FILE" 2>/dev/null | cut -d' ' -f1)

  if [ -n "$VERSION" ]; then
    echo "v$VERSION, $MTIME"
  else
    echo "$MTIME"
  fi
}

# Seed session with existing PDev docs (with version info)
cmd_seed() {
  local DOCS_PATH="${1:-$PWD/docs}"
  local SESSION_ID=$(get_session_id)
  local QUIET="${2:-}"  # Pass "quiet" to suppress output (for auto-seed)

  if [ -z "$SESSION_ID" ]; then
    error "No active session. Use: pdev-live start <command> <project>"
    return 1
  fi

  if [ ! -d "$DOCS_PATH" ]; then
    # Try common locations
    if [ -d "$PWD/docs" ]; then
      DOCS_PATH="$PWD/docs"
    elif [ -d "$PWD" ]; then
      DOCS_PATH="$PWD"
    else
      [ -z "$QUIET" ] && warn "Docs directory not found: $DOCS_PATH"
      return 0  # Not an error for auto-seed
    fi
  fi

  [ -z "$QUIET" ] && log "Seeding session with existing docs from: $DOCS_PATH"

  # PDev doc types in pipeline order
  local DOC_ORDER="IDEATION BENCHMARK GAP_ANALYSIS INNOVATION CAPABILITIES PRODUCT_SPEC DESIGN_SYSTEM DEVELOPMENT_SOP PIPELINE_VALIDATION EVALUATION"
  local FOUND=0
  local DOC_LIST=""

  for DOC_TYPE in $DOC_ORDER; do
    # Find matching file (case insensitive)
    local DOC_FILE=$(find "$DOCS_PATH" -maxdepth 1 -iname "*${DOC_TYPE}*.md" 2>/dev/null | head -1)

    if [ -n "$DOC_FILE" ] && [ -f "$DOC_FILE" ]; then
      local BASENAME=$(basename "$DOC_FILE")
      local DOC_INFO=$(get_doc_info "$DOC_FILE")
      DOC_LIST="${DOC_LIST}   • ${BASENAME} (${DOC_INFO})\n"
      cmd_doc "$BASENAME" "$DOC_FILE" >/dev/null 2>&1
      FOUND=$((FOUND + 1))
    fi
  done

  if [ $FOUND -eq 0 ]; then
    [ -z "$QUIET" ] && warn "No PDev docs found in: $DOCS_PATH"
  else
    if [ -z "$QUIET" ]; then
      success "Seeded $FOUND documents:"
      echo -e "$DOC_LIST"
    else
      log "Auto-seeded $FOUND existing docs"
    fi
  fi

  return 0
}

# Sync/refresh: re-fetch all docs from remote and push to PDev Live
cmd_sync() {
  local SESSION_ID=$(get_session_id)

  if [ -z "$SESSION_ID" ]; then
    error "No active session. Use: pdev-live start <command> <project>"
    return 1
  fi

  # Get remote info from session file
  local sf=$(get_session_file)
  local REMOTE_SERVER=$(jq -r '.server // empty' "$sf" 2>/dev/null)
  local REMOTE_PATH=$(jq -r '.remotePath // empty' "$sf" 2>/dev/null)

  if [ -z "$REMOTE_SERVER" ] || [ -z "$REMOTE_PATH" ]; then
    error "No remote path configured for this session"
    echo "Session file: $sf"
    cat "$sf" 2>/dev/null
    return 1
  fi

  log "Syncing docs from $REMOTE_SERVER:$REMOTE_PATH"

  # Re-fetch all docs from remote
  fetch_remote_docs "$REMOTE_SERVER" "$REMOTE_PATH" "$SESSION_ID"

  success "Sync complete - PDev Live updated with latest docs"
}

case "${1:-}" in
  start) shift; cmd_start "$@" ;;
  step) shift; cmd_step "$@" ;;
  doc) shift; cmd_doc "$@" ;;
  phase) shift; cmd_phase "$@" ;;
  end) shift; cmd_end "$@" ;;
  status) cmd_status ;;
  list) cmd_list ;;
  use) shift; cmd_use "$@" ;;
  id) get_session_id ;;
  manifest) shift; cmd_manifest "$@" ;;
  manifest-doc) shift; cmd_manifest_doc "$@" ;;
  manifest-get) cmd_manifest_get ;;
  share) shift; cmd_share "$@" ;;
  seed) shift; cmd_seed "$@" ;;
  sync) cmd_sync ;;
  *)
    echo "PDev Live Client (Multi-Session + Sharing)"
    echo ""
    echo "Session Commands:"
    echo "  start <type> [project]   Start or resume session"
    echo "  step <content>           Add output step"
    echo "  doc <name> <path>        Push full document"
    echo "  phase <num> <name>       Set current phase"
    echo "  seed [docs_path]         Seed session with existing PDev docs"
    echo "  sync                     Re-fetch all docs from remote (refresh)"
    echo "  end [status]             End session"
    echo "  status                   Show current session"
    echo "  list                     List all active sessions"
    echo "  use <project>            Switch to different project"
    echo "  id                       Output session ID"
    echo ""
    echo "Manifest Commands:"
    echo "  manifest [docs_path]     Set docs path for current project"
    echo "  manifest-doc <type> <file>  Register doc in manifest"
    echo "  manifest-get             Show manifest for current project"
    echo ""
    echo "Sharing Commands:"
    echo "  share [hours] [email]    Create guest link (default 24h)"
    echo ""
    echo "Session behavior:"
    echo "  - Resumes existing active session by default"
    echo "  - regen commands always create new session"
    echo "  - PDEV_FORCE_NEW=1 to force new session"
    ;;
esac
