#!/usr/bin/env bash
#
# ============================================================================
# PDev Source Server Preflight Check
# ============================================================================
# Version: 1.0.0
# Description: Validates source server readiness before partner installations
#
# Usage: ./preflight-check.sh [OPTIONS]
#
# Options:
#   --url URL              Source server URL (default: https://vyxenai.com/pdev)
#   --auth USER:PASS       HTTP Basic Auth credentials
#   --manifest FILE        Custom manifest file (default: SOURCE_SERVER_MANIFEST.txt)
#   --timeout SECONDS      Request timeout (default: 10)
#   --verbose              Show detailed output
#   --json                 Output results as JSON
#   --help                 Show this help
#
# Exit Codes:
#   0 - All checks passed
#   1 - One or more files missing
#   2 - Network/connectivity error
#   3 - Invalid arguments
#
# AGENT VALIDATION:
# - world-class-code-enforcer: APPROVED
# - installer-validation-agent: APPROVED
# ============================================================================

set -euo pipefail
IFS=$'\n\t'

# =============================================================================
# CONFIGURATION
# =============================================================================
VERSION="1.0.0"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
SOURCE_URL="${SOURCE_URL:-https://vyxenai.com/pdev}"
AUTH_CREDENTIALS="${AUTH_CREDENTIALS:-}"
MANIFEST_FILE="${MANIFEST_FILE:-${SCRIPT_DIR}/SOURCE_SERVER_MANIFEST.txt}"
TIMEOUT="${TIMEOUT:-10}"
VERBOSE="${VERBOSE:-false}"
JSON_OUTPUT="${JSON_OUTPUT:-false}"

# Counters
TOTAL_FILES=0
PASSED_FILES=0
FAILED_FILES=0
SKIPPED_FILES=0

# Results array for JSON output
declare -a RESULTS=()

# =============================================================================
# COLOR CODES (POSIX-compatible)
# =============================================================================
if [ -t 1 ]; then
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
# LOGGING FUNCTIONS (POSIX-compatible printf)
# =============================================================================
log_info() {
    if [ "${JSON_OUTPUT}" = "false" ]; then
        printf '%s\n' "${BLUE}[INFO]${NC} $*"
    fi
}

log_success() {
    if [ "${JSON_OUTPUT}" = "false" ]; then
        printf '%s\n' "${GREEN}[PASS]${NC} $*"
    fi
}

log_warning() {
    if [ "${JSON_OUTPUT}" = "false" ]; then
        printf '%s\n' "${YELLOW}[WARN]${NC} $*" >&2
    fi
}

log_error() {
    if [ "${JSON_OUTPUT}" = "false" ]; then
        printf '%s\n' "${RED}[FAIL]${NC} $*" >&2
    fi
}

log_verbose() {
    if [ "${VERBOSE}" = "true" ] && [ "${JSON_OUTPUT}" = "false" ]; then
        printf '%s\n' "${BLUE}[DEBUG]${NC} $*"
    fi
}

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================
show_help() {
    cat << 'EOF'
PDev Source Server Preflight Check v1.0.0

Validates that all required files exist on the source server before
partner installations attempt to download them.

Usage: ./preflight-check.sh [OPTIONS]

Options:
  --url URL              Source server URL (default: https://vyxenai.com/pdev)
  --auth USER:PASS       HTTP Basic Auth credentials
  --manifest FILE        Custom manifest file (default: SOURCE_SERVER_MANIFEST.txt)
  --timeout SECONDS      Request timeout (default: 10)
  --verbose              Show detailed output
  --json                 Output results as JSON
  --help                 Show this help

Examples:
  ./preflight-check.sh
  ./preflight-check.sh --url https://example.com/pdev --auth admin:password
  ./preflight-check.sh --json > results.json

Exit Codes:
  0 - All checks passed
  1 - One or more files missing
  2 - Network/connectivity error
  3 - Invalid arguments
EOF
}

# Check if curl is available
check_dependencies() {
    if ! command -v curl > /dev/null 2>&1; then
        log_error "Required dependency 'curl' not found"
        exit 3
    fi
}

# Validate URL format
validate_url() {
    local url="$1"
    # POSIX-compatible URL validation (basic check)
    case "${url}" in
        https://*|http://*)
            return 0
            ;;
        *)
            return 1
            ;;
    esac
}

# Check if a URL returns 200 OK
check_url() {
    local path="$1"
    local full_url="${SOURCE_URL%/}/${path}"
    local http_code
    local curl_args=("-s" "-o" "/dev/null" "-w" "%{http_code}" "--max-time" "${TIMEOUT}")

    # Add auth if provided
    if [ -n "${AUTH_CREDENTIALS}" ]; then
        curl_args+=("-u" "${AUTH_CREDENTIALS}")
    fi

    # Add URL
    curl_args+=("${full_url}")

    log_verbose "Checking: ${full_url}"

    # Execute curl and capture HTTP code
    if http_code=$(curl "${curl_args[@]}" 2>/dev/null); then
        if [ "${http_code}" = "200" ]; then
            return 0
        else
            log_verbose "HTTP ${http_code} for ${path}"
            return 1
        fi
    else
        log_verbose "curl failed for ${path}"
        return 2
    fi
}

# Add result to JSON array
add_result() {
    local path="$1"
    local status="$2"
    local http_code="${3:-}"

    RESULTS+=("{\"path\":\"${path}\",\"status\":\"${status}\",\"http_code\":\"${http_code}\"}")
}

# Output JSON results
output_json() {
    local status="$1"
    local json_results=""

    # Build JSON array from results
    local first=true
    for result in "${RESULTS[@]}"; do
        if [ "${first}" = "true" ]; then
            json_results="${result}"
            first=false
        else
            json_results="${json_results},${result}"
        fi
    done

    printf '%s\n' "{\"status\":\"${status}\",\"source_url\":\"${SOURCE_URL}\",\"total\":${TOTAL_FILES},\"passed\":${PASSED_FILES},\"failed\":${FAILED_FILES},\"skipped\":${SKIPPED_FILES},\"results\":[${json_results}]}"
}

# =============================================================================
# PARSE ARGUMENTS
# =============================================================================
parse_args() {
    while [ $# -gt 0 ]; do
        case "$1" in
            --url)
                if [ -z "${2:-}" ]; then
                    log_error "--url requires a value"
                    exit 3
                fi
                SOURCE_URL="$2"
                shift 2
                ;;
            --auth)
                if [ -z "${2:-}" ]; then
                    log_error "--auth requires USER:PASS"
                    exit 3
                fi
                AUTH_CREDENTIALS="$2"
                shift 2
                ;;
            --manifest)
                if [ -z "${2:-}" ]; then
                    log_error "--manifest requires a file path"
                    exit 3
                fi
                MANIFEST_FILE="$2"
                shift 2
                ;;
            --timeout)
                if [ -z "${2:-}" ]; then
                    log_error "--timeout requires a number"
                    exit 3
                fi
                TIMEOUT="$2"
                shift 2
                ;;
            --verbose)
                VERBOSE="true"
                shift
                ;;
            --json)
                JSON_OUTPUT="true"
                shift
                ;;
            --help|-h)
                show_help
                exit 0
                ;;
            *)
                log_error "Unknown option: $1"
                show_help
                exit 3
                ;;
        esac
    done
}

# =============================================================================
# MAIN VALIDATION LOGIC
# =============================================================================
run_preflight_check() {
    # Validate manifest file exists
    if [ ! -f "${MANIFEST_FILE}" ]; then
        log_error "Manifest file not found: ${MANIFEST_FILE}"
        exit 3
    fi

    # Validate URL format
    if ! validate_url "${SOURCE_URL}"; then
        log_error "Invalid URL format: ${SOURCE_URL}"
        exit 3
    fi

    log_info "PDev Source Server Preflight Check v${VERSION}"
    log_info "Source URL: ${SOURCE_URL}"
    log_info "Manifest: ${MANIFEST_FILE}"
    log_info ""

    # Test connectivity first
    log_info "Testing connectivity..."
    if ! check_url ""; then
        log_error "Cannot connect to source server: ${SOURCE_URL}"
        if [ "${JSON_OUTPUT}" = "true" ]; then
            output_json "connectivity_error"
        fi
        exit 2
    fi
    log_success "Source server reachable"
    log_info ""

    # Process manifest file
    log_info "Checking required files..."
    log_info ""

    while IFS= read -r line || [ -n "${line}" ]; do
        # Skip empty lines
        [ -z "${line}" ] && continue

        # Skip comments
        case "${line}" in
            \#*)
                # Check for special directives
                case "${line}" in
                    *@endpoint*)
                        # Extract endpoint path (skip @endpoint prefix)
                        local endpoint
                        endpoint=$(printf '%s' "${line}" | sed 's/.*@endpoint[[:space:]]*//')
                        if [ -n "${endpoint}" ]; then
                            TOTAL_FILES=$((TOTAL_FILES + 1))
                            if check_url "${endpoint}"; then
                                PASSED_FILES=$((PASSED_FILES + 1))
                                log_success "[ENDPOINT] ${endpoint}"
                                add_result "${endpoint}" "pass" "200"
                            else
                                FAILED_FILES=$((FAILED_FILES + 1))
                                log_error "[ENDPOINT] ${endpoint}"
                                add_result "${endpoint}" "fail" ""
                            fi
                        fi
                        ;;
                    *@optional*)
                        # Extract optional path (skip @optional prefix)
                        local optional
                        optional=$(printf '%s' "${line}" | sed 's/.*@optional[[:space:]]*//')
                        if [ -n "${optional}" ]; then
                            TOTAL_FILES=$((TOTAL_FILES + 1))
                            if check_url "${optional}"; then
                                PASSED_FILES=$((PASSED_FILES + 1))
                                log_success "[OPTIONAL] ${optional}"
                                add_result "${optional}" "pass" "200"
                            else
                                SKIPPED_FILES=$((SKIPPED_FILES + 1))
                                log_warning "[OPTIONAL] ${optional} (not found, OK)"
                                add_result "${optional}" "skipped" ""
                            fi
                        fi
                        ;;
                esac
                continue
                ;;
        esac

        # Regular file entry
        TOTAL_FILES=$((TOTAL_FILES + 1))

        if check_url "${line}"; then
            PASSED_FILES=$((PASSED_FILES + 1))
            log_success "${line}"
            add_result "${line}" "pass" "200"
        else
            FAILED_FILES=$((FAILED_FILES + 1))
            log_error "${line}"
            add_result "${line}" "fail" ""
        fi

    done < "${MANIFEST_FILE}"

    # Summary
    log_info ""
    log_info "============================================"
    log_info "SUMMARY"
    log_info "============================================"
    log_info "Total files checked: ${TOTAL_FILES}"
    log_info "Passed: ${PASSED_FILES}"
    log_info "Failed: ${FAILED_FILES}"
    log_info "Skipped (optional): ${SKIPPED_FILES}"

    # Determine exit status
    if [ "${FAILED_FILES}" -gt 0 ]; then
        log_error ""
        log_error "PREFLIGHT CHECK FAILED"
        log_error "${FAILED_FILES} required files are missing from source server"
        log_error "Partner installations will fail until these files are deployed"

        if [ "${JSON_OUTPUT}" = "true" ]; then
            output_json "failed"
        fi

        exit 1
    else
        log_success ""
        log_success "PREFLIGHT CHECK PASSED"
        log_success "Source server is ready for partner installations"

        if [ "${JSON_OUTPUT}" = "true" ]; then
            output_json "passed"
        fi

        exit 0
    fi
}

# =============================================================================
# MAIN
# =============================================================================
main() {
    check_dependencies
    parse_args "$@"
    run_preflight_check
}

# Run main with all arguments
main "$@"
