#!/bin/bash
# PDev Live - API Integration Validation
# Layer 4: API Integration Testing
# Tests all endpoints called by frontend for response codes, schema, performance

set -e

# Configuration
API_BASE="${PDEV_API_BASE:-https://walletsnack.com/pdev/api}"
AUTH_USER="${PDEV_AUTH_USER:-pdev}"
AUTH_PASS="${PDEV_AUTH_PASS:-PdevLive0987@@}"
ADMIN_KEY="${PDEV_ADMIN_KEY}"  # Required for admin endpoints
PDEV_TOKEN="${PDEV_TOKEN}"      # Required for authenticated endpoints

# Colors
RED='\033[0;31m'
YELLOW='\033[1;33m'
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Counters
PASS=0
WARN=0
BLOCK=0

# Output functions
pass() {
    echo -e "${GREEN}[PASS]${NC} $1"
    ((PASS++))
}

warn() {
    echo -e "${YELLOW}[WARN]${NC} $1"
    ((WARN++))
}

block() {
    echo -e "${RED}[BLOCK]${NC} $1"
    ((BLOCK++))
}

info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

# Measure response time and check status code
# Usage: test_endpoint "GET" "/health" 200
test_endpoint() {
    local method="$1"
    local endpoint="$2"
    local expected_status="$3"
    local description="${4:-$method $endpoint}"

    local url="$API_BASE$endpoint"
    local start=$(date +%s%3N)

    # Build curl command based on method
    local curl_cmd="curl -s -w '\n%{http_code}\n%{time_total}' -X $method"

    # Add auth if not a public endpoint
    if [[ "$endpoint" != "/version" && "$endpoint" != "/contract" ]]; then
        curl_cmd="$curl_cmd -u '$AUTH_USER:$AUTH_PASS'"
    fi

    # Add token header if available
    if [[ -n "$PDEV_TOKEN" ]]; then
        curl_cmd="$curl_cmd -H 'X-Pdev-Token: $PDEV_TOKEN'"
    fi

    # Add admin key header if testing admin endpoint
    if [[ -n "$ADMIN_KEY" && "$endpoint" =~ (delete|reset|settings) ]]; then
        curl_cmd="$curl_cmd -H 'X-Admin-Key: $ADMIN_KEY'"
    fi

    # Add JSON content-type for POST/PUT
    if [[ "$method" == "POST" || "$method" == "PUT" ]]; then
        curl_cmd="$curl_cmd -H 'Content-Type: application/json'"
    fi

    curl_cmd="$curl_cmd '$url'"

    # Execute request
    local response=$(eval $curl_cmd 2>&1)
    local end=$(date +%s%3N)

    # Parse response: last 2 lines are http_code and time_total
    local body=$(echo "$response" | head -n -2)
    local status=$(echo "$response" | tail -n 2 | head -n 1)
    local time_total=$(echo "$response" | tail -n 1)

    # Convert to milliseconds
    local response_time_ms=$(echo "$time_total * 1000" | bc | cut -d. -f1)

    # Check status code
    if [[ "$status" == "$expected_status" ]]; then
        # Check response time (WARN if P95 > 200ms)
        if [[ $response_time_ms -gt 200 ]]; then
            warn "$description → ${status} (${response_time_ms}ms - slow response)"
        else
            pass "$description → ${status} (${response_time_ms}ms)"
        fi
    elif [[ "$status" == "401" && -z "$PDEV_TOKEN" ]]; then
        warn "$description → 401 (auth required, PDEV_TOKEN not provided)"
    elif [[ "$status" == "401" && -z "$ADMIN_KEY" ]]; then
        warn "$description → 401 (admin key required, PDEV_ADMIN_KEY not provided)"
    else
        block "$description → Expected $expected_status, got $status (${response_time_ms}ms)"
        if [[ -n "$body" ]]; then
            echo "    Response: $(echo "$body" | head -c 200)"
        fi
    fi
}

# Test JSON response schema
# Usage: test_json_schema "/endpoint" "field1,field2,field3"
test_json_schema() {
    local endpoint="$1"
    local required_fields="$2"
    local description="${3:-Schema check $endpoint}"

    local url="$API_BASE$endpoint"
    local response=$(curl -s -u "$AUTH_USER:$AUTH_PASS" -H "X-Pdev-Token: $PDEV_TOKEN" "$url" 2>&1)

    # Check if valid JSON
    if ! echo "$response" | jq . >/dev/null 2>&1; then
        block "$description → Invalid JSON response"
        return
    fi

    # Check required fields
    IFS=',' read -ra FIELDS <<< "$required_fields"
    local missing_fields=()

    for field in "${FIELDS[@]}"; do
        if ! echo "$response" | jq -e ".$field" >/dev/null 2>&1; then
            missing_fields+=("$field")
        fi
    done

    if [[ ${#missing_fields[@]} -eq 0 ]]; then
        pass "$description → All required fields present"
    else
        block "$description → Missing fields: ${missing_fields[*]}"
    fi
}

# Test CORS headers
test_cors() {
    local endpoint="$1"
    local url="$API_BASE$endpoint"

    # Preflight OPTIONS request
    local headers=$(curl -s -I -X OPTIONS \
        -H "Origin: https://walletsnack.com" \
        -H "Access-Control-Request-Method: GET" \
        "$url" 2>&1)

    if echo "$headers" | grep -iq "Access-Control-Allow-Origin"; then
        local origin=$(echo "$headers" | grep -i "Access-Control-Allow-Origin" | cut -d: -f2- | tr -d ' \r\n')
        if [[ "$origin" == "*" || "$origin" == "https://walletsnack.com" ]]; then
            pass "CORS → Access-Control-Allow-Origin: $origin"
        else
            warn "CORS → Unexpected origin: $origin"
        fi
    else
        warn "CORS → No Access-Control-Allow-Origin header"
    fi

    if echo "$headers" | grep -iq "Access-Control-Allow-Credentials: true"; then
        pass "CORS → Credentials allowed"
    else
        warn "CORS → Credentials not allowed"
    fi
}

# Test SSE connection
test_sse() {
    local session_id="$1"
    local endpoint="/events/$session_id"
    local url="$API_BASE$endpoint"

    info "Testing SSE connection to $endpoint..."

    # Connect and read first few events (timeout after 5 seconds)
    local sse_output=$(timeout 5s curl -s -N -u "$AUTH_USER:$AUTH_PASS" \
        -H "X-Pdev-Token: $PDEV_TOKEN" \
        "$url" 2>&1 || true)

    if [[ -n "$sse_output" ]]; then
        # Check for proper SSE format: data: {...}
        if echo "$sse_output" | grep -q "^data:"; then
            pass "SSE → Connection established, event format valid"
        else
            warn "SSE → Connected but unexpected format"
        fi
    else
        warn "SSE → No events received (session may be inactive)"
    fi
}

# Test rate limiting
test_rate_limit() {
    local endpoint="/sessions"
    local url="$API_BASE$endpoint"

    info "Testing rate limiting (sending 50 rapid requests)..."

    local rate_limited=0
    for i in {1..50}; do
        local status=$(curl -s -o /dev/null -w '%{http_code}' \
            -u "$AUTH_USER:$AUTH_PASS" \
            -H "X-Pdev-Token: $PDEV_TOKEN" \
            "$url" 2>&1)

        if [[ "$status" == "429" ]]; then
            rate_limited=1
            break
        fi
    done

    if [[ $rate_limited -eq 1 ]]; then
        pass "Rate Limiting → 429 returned after threshold"
    else
        warn "Rate Limiting → No 429 after 50 requests (may not be enabled)"
    fi
}

# Test error scenarios
test_error_scenarios() {
    info "Testing error scenarios..."

    # Invalid session ID (should return 404)
    test_endpoint "GET" "/sessions/00000000-0000-0000-0000-000000000000" 404 "Invalid session ID"

    # Missing admin key for protected endpoint
    local old_admin_key="$ADMIN_KEY"
    ADMIN_KEY=""
    test_endpoint "DELETE" "/sessions/test-session" 401 "Delete session without admin key"
    ADMIN_KEY="$old_admin_key"

    # Malformed JSON body (requires actual POST with bad JSON)
    local bad_json_response=$(curl -s -w '\n%{http_code}' -X POST \
        -u "$AUTH_USER:$AUTH_PASS" \
        -H "X-Pdev-Token: $PDEV_TOKEN" \
        -H "Content-Type: application/json" \
        -d '{invalid json}' \
        "$API_BASE/sessions" 2>&1)
    local bad_json_status=$(echo "$bad_json_response" | tail -n 1)

    if [[ "$bad_json_status" == "400" ]]; then
        pass "Malformed JSON → 400 Bad Request"
    else
        warn "Malformed JSON → Expected 400, got $bad_json_status"
    fi
}

# Main test execution
main() {
    echo "=========================================="
    echo "PDev Live - API Integration Validation"
    echo "=========================================="
    echo "API Base: $API_BASE"
    echo "Auth User: $AUTH_USER"
    echo "PDEV_TOKEN: ${PDEV_TOKEN:0:10}... (${#PDEV_TOKEN} chars)"
    echo ""

    # Check prerequisites
    if [[ -z "$PDEV_TOKEN" ]]; then
        warn "PDEV_TOKEN not set - some tests will be skipped"
        echo "  Set with: export PDEV_TOKEN=<your-token>"
        echo ""
    fi

    info "=== Testing Public Endpoints ==="
    test_endpoint "GET" "/version" 200 "GET /version"
    test_endpoint "GET" "/contract" 200 "GET /contract"

    info ""
    info "=== Testing Authenticated Endpoints ==="
    test_endpoint "GET" "/health" 200 "GET /health"
    test_endpoint "GET" "/sessions/active" 200 "GET /sessions/active"
    test_endpoint "GET" "/sessions/history" 200 "GET /sessions/history"
    test_endpoint "GET" "/servers" 200 "GET /servers"
    test_endpoint "GET" "/projects" 200 "GET /projects"
    test_endpoint "GET" "/manifests" 200 "GET /manifests"

    info ""
    info "=== Testing Session Endpoints ==="
    test_endpoint "GET" "/sessions/find-active" 200 "GET /sessions/find-active"

    # Create test session to validate session-specific endpoints
    if [[ -n "$PDEV_TOKEN" ]]; then
        info "Creating test session..."
        local create_response=$(curl -s -X POST \
            -u "$AUTH_USER:$AUTH_PASS" \
            -H "X-Pdev-Token: $PDEV_TOKEN" \
            -H "Content-Type: application/json" \
            -d '{"server":"dolovdev","project":"test-api-validation","commandType":"idea","hostname":"localhost","projectPath":"/tmp/test","cwd":"/tmp/test"}' \
            "$API_BASE/sessions" 2>&1)

        local session_id=$(echo "$create_response" | jq -r '.sessionId // empty' 2>/dev/null)

        if [[ -n "$session_id" ]]; then
            pass "Test session created: $session_id"

            # Test session-specific endpoints
            test_endpoint "GET" "/sessions/$session_id" 200 "GET /sessions/:id"
            test_endpoint "GET" "/sessions/$session_id/steps" 200 "GET /sessions/:id/steps"
            test_endpoint "POST" "/sessions/$session_id/complete" 200 "POST /sessions/:id/complete"

            # Test SSE
            test_sse "$session_id"

            # Test guest link creation
            info "Testing guest link creation..."
            local share_token_response=$(curl -s -X POST \
                -u "$AUTH_USER:$AUTH_PASS" \
                "$API_BASE/share-token" 2>&1)
            local share_token=$(echo "$share_token_response" | jq -r '.token // empty' 2>/dev/null)

            if [[ -n "$share_token" ]]; then
                local guest_response=$(curl -s -X POST \
                    -u "$AUTH_USER:$AUTH_PASS" \
                    -H "X-Share-Token: $share_token" \
                    -H "Content-Type: application/json" \
                    -d "{\"sessionId\":\"$session_id\",\"expiresInHours\":24}" \
                    "$API_BASE/guest-links" 2>&1)

                local guest_token=$(echo "$guest_response" | jq -r '.token // empty' 2>/dev/null)

                if [[ -n "$guest_token" ]]; then
                    pass "Guest link created: $guest_token"
                    test_endpoint "GET" "/guest/$guest_token" 200 "GET /guest/:token"
                else
                    warn "Guest link creation failed"
                fi
            else
                warn "Share token creation failed"
            fi

            # Clean up test session (if ADMIN_KEY provided)
            if [[ -n "$ADMIN_KEY" ]]; then
                info "Cleaning up test session..."
                curl -s -X DELETE \
                    -u "$AUTH_USER:$AUTH_PASS" \
                    -H "X-Admin-Key: $ADMIN_KEY" \
                    "$API_BASE/sessions/$session_id" >/dev/null 2>&1
            fi
        else
            warn "Failed to create test session - skipping session-specific tests"
        fi
    else
        warn "PDEV_TOKEN not set - skipping session creation tests"
    fi

    info ""
    info "=== Testing CORS Headers ==="
    test_cors "/sessions/active"

    info ""
    info "=== Testing Error Scenarios ==="
    test_error_scenarios

    info ""
    info "=== Testing Rate Limiting ==="
    test_rate_limit

    echo ""
    echo "=========================================="
    echo "API Validation Results"
    echo "=========================================="
    echo -e "${GREEN}PASS:${NC} $PASS"
    echo -e "${YELLOW}WARN:${NC} $WARN"
    echo -e "${RED}BLOCK:${NC} $BLOCK"
    echo ""

    if [[ $BLOCK -gt 0 ]]; then
        echo -e "${RED}VERDICT: BLOCK${NC} - Critical API issues found"
        exit 1
    elif [[ $WARN -gt 0 ]]; then
        echo -e "${YELLOW}VERDICT: WARN${NC} - API functional with minor issues"
        exit 0
    else
        echo -e "${GREEN}VERDICT: PASS${NC} - All API endpoints validated"
        exit 0
    fi
}

# Run tests
main "$@"
