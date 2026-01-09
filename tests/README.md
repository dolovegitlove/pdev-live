# PDev Live - API Validation Tests

## Quick Start

### 1. Get Your Server Token

First, you need a valid server token to authenticate API requests.

**Option A: Use existing token**
```bash
# Check if you already have a token
grep PDEV_TOKEN ~/.bashrc  # or ~/.zshrc
```

**Option B: Generate new token (requires admin access)**
```bash
# On production server
ssh acme
sudo -u pdev psql pdev_live -c \
  "INSERT INTO server_tokens (token, server_name)
   VALUES ('$(openssl rand -base64 32)', 'dolovdev')
   RETURNING token;"
```

### 2. Set Environment Variables

```bash
# Required
export PDEV_TOKEN="your-server-token-here"

# Optional (defaults shown)
export PDEV_API_BASE="https://walletsnack.com/pdev/api"
export PDEV_AUTH_USER="pdev"
export PDEV_AUTH_PASS="PdevLive0987@@"

# Only if testing admin endpoints
export PDEV_ADMIN_KEY="your-admin-key-here"
```

### 3. Run Validation

```bash
cd /Users/dolovdev/projects/pdev-live/tests
./validate-api.sh
```

## Test Coverage

### Layer 4: API Integration

**Tests:**
1. ✅ All API endpoints called by frontend
2. ✅ HTTP status code validation (200/201/204/401/404/429/500)
3. ✅ Response schema validation (JSON structure)
4. ✅ CORS headers check
5. ✅ SSE connection and event format
6. ✅ Rate limiting (429 response)
7. ✅ Error scenarios (invalid session, missing auth, malformed JSON)
8. ✅ Response time measurement (WARN if P95 > 200ms)

**Files Tested:**
- `/Users/dolovdev/projects/pdev-live/server/server.js` (API routes)
- `/Users/dolovdev/projects/pdev-live/frontend/live.html` (fetch calls)
- `/Users/dolovdev/projects/pdev-live/frontend/session.html` (SSE, guest links)
- `/Users/dolovdev/projects/pdev-live/frontend/dashboard.html` (session mgmt)

## Manual Testing

### Test Individual Endpoints

```bash
# Public endpoints (no auth)
curl https://walletsnack.com/pdev/api/version

# Authenticated endpoints
curl -u "pdev:PdevLive0987@@" \
  -H "X-Pdev-Token: $PDEV_TOKEN" \
  https://walletsnack.com/pdev/api/health

# Create session
curl -X POST -u "pdev:$PDEV_AUTH_PASS" \
  -H "X-Pdev-Token: $PDEV_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{"server":"dolovdev","project":"test","commandType":"idea","hostname":"localhost","projectPath":"/tmp","cwd":"/tmp"}' \
  https://walletsnack.com/pdev/api/sessions

# SSE connection (keep-alive, Ctrl+C to stop)
curl -N -u "pdev:$PDEV_AUTH_PASS" \
  -H "X-Pdev-Token: $PDEV_TOKEN" \
  https://walletsnack.com/pdev/api/events/YOUR-SESSION-ID
```

### Measure Response Time

```bash
# Single request
curl -s -w '\n%{time_total}\n' \
  -u "pdev:$PDEV_AUTH_PASS" \
  -H "X-Pdev-Token: $PDEV_TOKEN" \
  https://walletsnack.com/pdev/api/sessions/active

# Average over 10 requests
for i in {1..10}; do
  curl -s -w '%{time_total}\n' -o /dev/null \
    -u "pdev:$PDEV_AUTH_PASS" \
    -H "X-Pdev-Token: $PDEV_TOKEN" \
    https://walletsnack.com/pdev/api/health
done | awk '{sum+=$1; count++} END {print "Avg:", sum/count, "s"}'
```

## Interpreting Results

### Exit Codes
- `0` = PASS or WARN (non-blocking)
- `1` = BLOCK (critical issues found)

### Result Categories

**PASS** (Green)
- Endpoint returns expected status code
- Response time < 200ms
- Valid JSON schema

**WARN** (Yellow)
- Response time > 200ms (slow but functional)
- Missing optional headers (e.g., CORS)
- Auth required but token not provided
- Non-critical issues

**BLOCK** (Red)
- Unexpected status code (e.g., expected 200 got 500)
- Invalid JSON response
- Timeout (> 30s)
- Critical API failure

### Example Output

```
==========================================
PDev Live - API Integration Validation
==========================================
API Base: https://walletsnack.com/pdev/api
Auth User: pdev
PDEV_TOKEN: eF9kZXZfc... (32 chars)

[INFO] === Testing Public Endpoints ===
[PASS] GET /version → 200 (45ms)
[PASS] GET /contract → 200 (52ms)

[INFO] === Testing Authenticated Endpoints ===
[PASS] GET /health → 200 (78ms)
[PASS] GET /sessions/active → 200 (123ms)
[WARN] GET /sessions/history → 200 (245ms - slow response)

[INFO] === Testing Session Endpoints ===
[PASS] Test session created: 550e8400-e29b-41d4-a716-446655440000
[PASS] GET /sessions/:id → 200 (89ms)
[PASS] POST /sessions/:id/complete → 200 (102ms)
[PASS] SSE → Connection established, event format valid

[INFO] === Testing CORS Headers ===
[PASS] CORS → Access-Control-Allow-Origin: https://walletsnack.com
[PASS] CORS → Credentials allowed

[INFO] === Testing Error Scenarios ===
[PASS] Invalid session ID → 404
[PASS] Delete session without admin key → 401
[PASS] Malformed JSON → 400 Bad Request

[INFO] === Testing Rate Limiting ===
[PASS] Rate Limiting → 429 returned after threshold

==========================================
API Validation Results
==========================================
PASS: 15
WARN: 1
BLOCK: 0

VERDICT: PASS - All API endpoints validated
```

## Common Issues

### Issue: "Missing X-Pdev-Token header"
**Cause:** PDEV_TOKEN not set or invalid
**Fix:**
```bash
export PDEV_TOKEN="your-token-here"
# Verify it's set
echo $PDEV_TOKEN
```

### Issue: "401 Unauthorized"
**Cause:** HTTP Basic Auth credentials incorrect
**Fix:**
```bash
export PDEV_AUTH_USER="pdev"
export PDEV_AUTH_PASS="PdevLive0987@@"
```

### Issue: "Connection refused"
**Cause:** API server not running
**Fix:**
```bash
# Check if server running
ssh acme "pm2 status | grep pdev"
# Restart if needed
ssh acme "pm2 restart pdev-live-server"
```

### Issue: "Slow response (>200ms)"
**Cause:** Database query optimization needed
**Fix:**
- Check PostgreSQL slow query log
- Add indexes to frequently queried columns
- Review connection pool settings

## Advanced Testing

### Load Testing (100 concurrent requests)

```bash
# Install Apache Bench
brew install apache2  # macOS
sudo apt install apache2-utils  # Linux

# Test endpoint
ab -n 100 -c 10 -H "X-Pdev-Token: $PDEV_TOKEN" \
  -A "pdev:$PDEV_AUTH_PASS" \
  https://walletsnack.com/pdev/api/health

# Expected output:
# Requests per second: > 50
# 95% of requests: < 200ms
```

### Schema Validation with jq

```bash
# Test session response schema
curl -s -u "pdev:$PDEV_AUTH_PASS" \
  -H "X-Pdev-Token: $PDEV_TOKEN" \
  https://walletsnack.com/pdev/api/sessions/active | \
  jq '.[0] | {id, project_name, server_origin, session_status}'

# Expected output:
# {
#   "id": "uuid",
#   "project_name": "string",
#   "server_origin": "string",
#   "session_status": "active"
# }
```

### SSE Event Monitoring

```bash
# Connect to SSE stream and parse events
curl -N -s -u "pdev:$PDEV_AUTH_PASS" \
  -H "X-Pdev-Token: $PDEV_TOKEN" \
  https://walletsnack.com/pdev/api/events | \
  grep --line-buffered '^data:' | \
  while read -r line; do
    echo "$line" | sed 's/^data: //' | jq '.type'
  done

# Expected output (as events arrive):
# "init"
# "step"
# "complete"
```

## CI/CD Integration

### GitHub Actions

```yaml
name: API Validation
on: [push]
jobs:
  validate:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v2
      - name: Run API Tests
        env:
          PDEV_TOKEN: ${{ secrets.PDEV_TOKEN }}
          PDEV_ADMIN_KEY: ${{ secrets.PDEV_ADMIN_KEY }}
        run: |
          cd tests
          ./validate-api.sh
```

### Pre-Deployment Hook

```bash
#!/bin/bash
# deploy-hooks/pre-deploy.sh

# Run API validation before deploying
cd /path/to/pdev-live/tests
./validate-api.sh

if [ $? -eq 1 ]; then
  echo "❌ API validation failed - aborting deployment"
  exit 1
fi

echo "✅ API validation passed - proceeding with deployment"
```

## Documentation

- **Full Report:** `/Users/dolovdev/projects/pdev-live/tests/API_VALIDATION_REPORT.md`
- **Validation Script:** `/Users/dolovdev/projects/pdev-live/tests/validate-api.sh`
- **Server Routes:** `/Users/dolovdev/projects/pdev-live/server/server.js`

## Support

For issues or questions:
1. Check `API_VALIDATION_REPORT.md` for endpoint details
2. Review server logs: `ssh acme "pm2 logs pdev-live-server --lines 100"`
3. Check database: `ssh acme "sudo -u pdev psql pdev_live -c 'SELECT COUNT(*) FROM pdev_sessions;'"`
