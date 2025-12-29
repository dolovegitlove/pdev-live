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

PDEV_LIVE_URL="${PDEV_LIVE_URL:-https://walletsnack.com/pdev/api}"

detect_server() {
  if [ -n "$PDEV_SERVER" ]; then
    echo "$PDEV_SERVER"
    return
  fi
  HOSTNAME=$(hostname -s 2>/dev/null || hostname)
  case "$HOSTNAME" in
    *dolovdev*|Dolovs*|dolov-mac*|Dolov*) echo "dolovdev" ;;
    srv*|acme*) echo "acme" ;;
    *ittz*) echo "ittz" ;;
    *dolov*) echo "dolov" ;;
    WIN*|DESKTOP*|*wdress*) echo "wdress" ;;
    *) echo "dolovdev" ;;
  esac
}

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

restore_session_from_server() {
  local project="$1"
  local EXISTING=$(find_active_session "$project")
  local FOUND=$(echo "$EXISTING" | jq -r '.found // false' 2>/dev/null)

  if [ "$FOUND" = "true" ]; then
    local SESSION_ID=$(echo "$EXISTING" | jq -r '.session.id' 2>/dev/null)
    local CMD=$(echo "$EXISTING" | jq -r '.session.command_type' 2>/dev/null)
    local STEPS=$(echo "$EXISTING" | jq -r '.session.step_count // 0' 2>/dev/null)

    local sf=$(get_session_file "$project")
    local pf=$(get_phase_file "$project")
    echo "{\"sessionId\": \"$SESSION_ID\", \"stepCount\": $STEPS, \"server\": \"$PDEV_SERVER\", \"project\": \"$project\", \"command\": \"$CMD\"}" > "$sf"
    [ ! -f "$pf" ] && echo "{\"phaseNum\": 0, \"phaseName\": \"\"}" > "$pf"
    warn "Restored session from server: $SESSION_ID"
  fi
}

get_session_id() {
  local project=$(get_current_project)
  local sf=$(get_session_file "$project")

  # If local file missing but project is set, try to restore from server
  if [ ! -f "$sf" ] && [ -n "$project" ]; then
    restore_session_from_server "$project"
  fi

  if [ -f "$sf" ]; then
    jq -r '.sessionId // empty' "$sf" 2>/dev/null
  fi
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

# Find existing active session on server
find_active_session() {
  local project="$1"
  curl -s "$PDEV_LIVE_URL/sessions/find-active?server=$PDEV_SERVER&project=$project" 2>/dev/null
}

cmd_start() {
  local COMMAND_TYPE="${1:-unknown}"
  local PROJECT_NAME="${2:-$(basename "$PWD")}"

  # Force new session for regen commands OR explicit override
  if should_force_new "$COMMAND_TYPE"; then
    log "Creating new session (forced): /$COMMAND_TYPE for $PROJECT_NAME"
  else
    # Find ANY existing session for this project (active OR completed)
    local EXISTING=$(curl -s "$PDEV_LIVE_URL/sessions/find-session?server=$PDEV_SERVER&project=$PROJECT_NAME" 2>/dev/null)
    local FOUND=$(echo "$EXISTING" | jq -r '.found // false' 2>/dev/null)

    if [ "$FOUND" = "true" ]; then
      local EXISTING_ID=$(echo "$EXISTING" | jq -r '.session.id' 2>/dev/null)
      local STATUS=$(echo "$EXISTING" | jq -r '.session.session_status' 2>/dev/null)
      local STEP_COUNT=$(echo "$EXISTING" | jq -r '.session.step_count // 0' 2>/dev/null)

      # Reopen if completed
      if [ "$STATUS" != "active" ]; then
        curl -s -X POST "$PDEV_LIVE_URL/sessions/$EXISTING_ID/reopen" \
          -H "Content-Type: application/json" \
          -d '{}' >/dev/null 2>&1
        log "Reopened completed session for $PROJECT_NAME"
      fi

      # Update local session file
      local sf=$(get_session_file "$PROJECT_NAME")
      local pf=$(get_phase_file "$PROJECT_NAME")
      echo "{\"sessionId\": \"$EXISTING_ID\", \"stepCount\": $STEP_COUNT, \"server\": \"$PDEV_SERVER\", \"project\": \"$PROJECT_NAME\"}" > "$sf"
      [ ! -f "$pf" ] && echo "{\"phaseNum\": 0, \"phaseName\": \"\"}" > "$pf"
      echo "$PROJECT_NAME" > "$SESSIONS_DIR/default-$PDEV_SERVER.txt"

      success "Resumed session: $EXISTING_ID ($STEP_COUNT steps)"
      echo "View at: https://walletsnack.com/pdev/live/session.html?id=$EXISTING_ID"
      echo "$EXISTING_ID"
      return 0
    fi
  fi

  # Create new session
  log "Creating new session: /$COMMAND_TYPE for $PROJECT_NAME on $PDEV_SERVER"

  RESPONSE=$(curl -s -X POST "$PDEV_LIVE_URL/sessions" \
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
    echo "{\"sessionId\": \"$SESSION_ID\", \"stepCount\": 0, \"server\": \"$PDEV_SERVER\", \"project\": \"$PROJECT_NAME\"}" > "$sf"
    echo "{\"phaseNum\": 0, \"phaseName\": \"\"}" > "$pf"
    echo "$PROJECT_NAME" > "$SESSIONS_DIR/default-$PDEV_SERVER.txt"
    success "Session created: $SESSION_ID"
    echo "View at: https://walletsnack.com/pdev/live/session.html?id=$SESSION_ID"
    echo "$SESSION_ID"
  else
    error "Failed to create session: $RESPONSE"
    return 1
  fi
}

cmd_step() {
  local CONTENT="$*"

  # Read from stdin when content is "-" or empty
  if [ "$CONTENT" = "-" ] || [ -z "$CONTENT" ]; then
    CONTENT=$(cat)
  fi

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

  RESPONSE=$(curl -s -X POST "$PDEV_LIVE_URL/sessions/$SESSION_ID/steps" \
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

  if [ ! -f "$DOC_PATH" ]; then
    error "File not found: $DOC_PATH"
    return 1
  fi

  local CONTENT=$(cat "$DOC_PATH")
  local CONTENT_SIZE=$(echo "$CONTENT" | wc -c | tr -d ' ')

  log "Pushing document: $DOC_NAME ($CONTENT_SIZE bytes)"

  local pf=$(get_phase_file)
  local PHASE_NUM=""
  local PHASE_NAME=""
  if [ -f "$pf" ]; then
    PHASE_NUM=$(jq -r '.phaseNum // empty' "$pf" 2>/dev/null)
    PHASE_NAME=$(jq -r '.phaseName // empty' "$pf" 2>/dev/null)
  fi

  RESPONSE=$(curl -s -X POST "$PDEV_LIVE_URL/sessions/$SESSION_ID/steps" \
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
    curl -s -X POST "$PDEV_LIVE_URL/sessions/$SESSION_ID/steps" \
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

  curl -s -X POST "$PDEV_LIVE_URL/sessions/$SESSION_ID/complete" \
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
    echo "View at: https://walletsnack.com/pdev/live/session.html?id=$(get_session_id)"
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

  RESPONSE=$(curl -s -X PUT "$PDEV_LIVE_URL/manifests/$PDEV_SERVER/$PROJECT" \
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

  RESPONSE=$(curl -s -X PATCH "$PDEV_LIVE_URL/manifests/$PDEV_SERVER/$PROJECT/doc" \
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

  RESPONSE=$(curl -s "$PDEV_LIVE_URL/manifests/$PDEV_SERVER/$PROJECT" 2>/dev/null)

  if echo "$RESPONSE" | jq -e '.error' >/dev/null 2>&1; then
    warn "No manifest found for $PDEV_SERVER/$PROJECT"
  else
    echo "$RESPONSE" | jq .
  fi
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
  *)
    echo "PDev Live Client (Multi-Session + Resume + Manifests)"
    echo ""
    echo "Session Commands:"
    echo "  start <type> [project]   Start or resume session"
    echo "  step <content>           Add output step"
    echo "  doc <name> <path>        Push full document"
    echo "  phase <num> <name>       Set current phase"
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
    echo "Session behavior:"
    echo "  - Resumes existing active session by default"
    echo "  - regen commands always create new session"
    echo "  - PDEV_FORCE_NEW=1 to force new session"
    ;;
esac
