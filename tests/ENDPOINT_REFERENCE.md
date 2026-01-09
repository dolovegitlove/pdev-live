# PDev Live - API Endpoint Reference
**Quick reference for all API endpoints**

## Base URLs
- **Production:** `https://walletsnack.com/pdev/api`
- **Local Dev:** `http://localhost:4173/pdev/api`

## Authentication

| Header | Required For | Value Format | Notes |
|--------|--------------|--------------|-------|
| `Authorization` | All (HTTP Basic) | `Basic base64(user:pass)` | nginx layer |
| `X-Pdev-Token` | Most endpoints | Server token string | DB-validated |
| `X-Admin-Key` | Admin endpoints | Admin key string | Timing-safe check |
| `X-Share-Token` | Guest link creation | One-time token | 5min expiry |

## Complete Endpoint List

### Public Endpoints (No X-Pdev-Token Required)

| Endpoint | Method | Response | Frontend Usage | Notes |
|----------|--------|----------|----------------|-------|
| `/version` | GET | `{ version, commit, ... }` | version-check.js | Version info |
| `/contract` | GET | `{ PIPELINE_DOCS: [...] }` | - | Doc contract |
| `/guest/:token` | GET | `{ sessionId }` | session.html:202 | Validate guest link |

### Session Management

| Endpoint | Method | Request Body | Response | Frontend Usage |
|----------|--------|--------------|----------|----------------|
| `/sessions` | POST | `{ server, project, commandType, hostname, projectPath, cwd }` | `{ success: true, sessionId: UUID }` | client.sh |
| `/sessions/:id` | GET | - | `{ id, project_name, server_origin, steps: [...] }` | session.html:210 |
| `/sessions/:id/steps` | GET | - | `[ {step_type, content_html, ...}, ... ]` | session.html:931 |
| `/sessions/:id/steps` | POST | `{ type, content, documentName?, phaseName?, ... }` | `{ success: true, stepId: UUID }` | client.sh |
| `/sessions/:id/complete` | POST | - | `{ success: true }` | session.html:792 |
| `/sessions/:id/reopen` | POST | - | `{ success: true }` | dashboard.html |
| `/sessions/:id` | DELETE | - | `204 No Content` | dashboard.html (admin) |
| `/sessions` | DELETE | - | `{ success: true, count: N }` | - (admin) |
| `/sessions/active` | GET | - | `[ {session}, ... ]` | dashboard.html |
| `/sessions/history` | GET | - | `[ {session}, ... ]` | dashboard.html |
| `/sessions/find-active` | GET | `?server=X&project=Y` | `{ sessionId: UUID }` or `{}` | client.sh |

### Guest Link Management

| Endpoint | Method | Request Body | Response | Frontend Usage |
|----------|--------|--------------|----------|----------------|
| `/share-token` | POST | - | `{ token, expiresIn: 300 }` | session.html:551 |
| `/guest-links` | POST | `{ sessionId, email?, expiresInHours }` | `{ token, expiresAt }` | session.html:555 |
| `/guest-links` | GET | - | `[ {token, sessionId, email, expiresAt}, ... ]` | settings.html (admin) |
| `/guest-links/:token` | DELETE | - | `204 No Content` | settings.html (admin) |

### Project/Server Management

| Endpoint | Method | Query Params | Response | Frontend Usage |
|----------|--------|--------------|----------|----------------|
| `/servers` | GET | - | `[ {name, displayName}, ... ]` | dashboard.html |
| `/projects` | GET | - | `[ {server, project, lastSession}, ... ]` | projects.html:571 |
| `/servers/:server/sessions` | GET | - | `[ {session}, ... ]` | - |
| `/projects/:server/:project/sessions` | GET | - | `[ {session}, ... ]` | project.html |

### Manifest/Document Management

| Endpoint | Method | Request Body | Response | Frontend Usage |
|----------|--------|--------------|----------|----------------|
| `/manifests` | GET | - | `[ {server, project, docs: {...}}, ... ]` | projects.html |
| `/manifests/:server/:project` | GET | - | `{ docs: {type: filename}, lastModified }` | session.html:432 |
| `/manifests/:server/:project` | PUT | `{ docs: {type: filename} }` | `{ success: true }` | client.sh |

### Server-Sent Events (SSE)

| Endpoint | Method | Event Format | Frontend Usage |
|----------|--------|--------------|----------------|
| `/events/:sessionId` | GET (SSE) | `data: {type: "step", step: {...}}` | session.html:241 |
| `/events` | GET (SSE) | `data: {type: "init/step/reset"}` | live.html:84 |

**SSE Event Types:**
- `init` - Initial session state
- `step` - New step added
- `complete` - Session completed
- `reset` - Session reset
- `session_created` - New session created (global stream only)

### Admin Endpoints

| Endpoint | Method | Request Body | Response | Notes |
|----------|--------|--------------|----------|-------|
| `/reset` | POST | - | `{ completed: N }` | live.html:240 - Resets active sessions |
| `/settings` | GET | - | `{ key: value, ... }` | settings.html:258 |
| `/settings` | POST | `{ key: value, ... }` | `{ success: true }` | settings.html:258 |
| `/admin/registration-code` | POST | `{ server }` | `{ code, expiresAt }` | - |

### Health/Status

| Endpoint | Method | Response | Notes |
|----------|--------|----------|-------|
| `/health` | GET | `{ status: "healthy", database: "connected", ... }` | Health check |

## Request Examples

### Create Session
```bash
curl -X POST https://walletsnack.com/pdev/api/sessions \
  -u "pdev:PdevLive0987@@" \
  -H "X-Pdev-Token: $PDEV_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "server": "dolovdev",
    "project": "my-project",
    "commandType": "idea",
    "hostname": "localhost",
    "projectPath": "/Users/dolovdev/projects/my-project",
    "cwd": "/Users/dolovdev/projects/my-project"
  }'

# Response:
# {"success":true,"sessionId":"550e8400-e29b-41d4-a716-446655440000"}
```

### Add Step to Session
```bash
curl -X POST https://walletsnack.com/pdev/api/sessions/550e8400.../steps \
  -u "pdev:PdevLive0987@@" \
  -H "X-Pdev-Token: $PDEV_TOKEN" \
  -H "Content-Type: application/json" \
  -d '{
    "type": "output",
    "content": "# Phase 1: Discovery\n\nAnalyzing requirements...",
    "phaseName": "Discovery",
    "phaseNumber": 1
  }'

# Response:
# {"success":true,"stepId":"660f9511-f39c-52e5-b827-557766551111"}
```

### Create Guest Link
```bash
# Step 1: Get share token
curl -X POST https://walletsnack.com/pdev/api/share-token \
  -u "pdev:PdevLive0987@@"

# Response: {"token":"abcd1234...","expiresIn":300}

# Step 2: Create guest link
curl -X POST https://walletsnack.com/pdev/api/guest-links \
  -u "pdev:PdevLive0987@@" \
  -H "X-Share-Token: abcd1234..." \
  -H "Content-Type: application/json" \
  -d '{
    "sessionId": "550e8400-e29b-41d4-a716-446655440000",
    "email": "client@example.com",
    "expiresInHours": 72
  }'

# Response:
# {"token":"xyz789...","expiresAt":"2026-01-11T12:00:00.000Z"}

# Guest URL: https://walletsnack.com/pdev/live/session.html?guest=xyz789...
```

### Connect to SSE Stream
```bash
# Session-specific events
curl -N https://walletsnack.com/pdev/api/events/550e8400... \
  -u "pdev:PdevLive0987@@" \
  -H "X-Pdev-Token: $PDEV_TOKEN"

# Output:
# data: {"type":"step","step":{"step_type":"output","content_html":"<h1>Phase 1</h1>..."}}
#
# data: {"type":"complete"}
```

### Get Session Details
```bash
curl https://walletsnack.com/pdev/api/sessions/550e8400... \
  -u "pdev:PdevLive0987@@" \
  -H "X-Pdev-Token: $PDEV_TOKEN"

# Response:
# {
#   "id": "550e8400-e29b-41d4-a716-446655440000",
#   "server_origin": "dolovdev",
#   "project_name": "my-project",
#   "command_type": "idea",
#   "session_status": "active",
#   "started_at": "2026-01-08T12:00:00.000Z",
#   "completed_at": null,
#   "duration_seconds": null,
#   "hostname": "localhost",
#   "project_path": "/Users/dolovdev/projects/my-project",
#   "cwd": "/Users/dolovdev/projects/my-project",
#   "steps": [
#     {
#       "id": "660f9511-f39c-52e5-b827-557766551111",
#       "step_type": "output",
#       "content_markdown": "# Phase 1: Discovery\n\nAnalyzing...",
#       "content_html": "<h1>Phase 1: Discovery</h1><p>Analyzing...</p>",
#       "document_name": null,
#       "phase_name": "Discovery",
#       "phase_number": 1,
#       "created_at": "2026-01-08T12:00:30.000Z"
#     }
#   ]
# }
```

## Error Responses

### 400 Bad Request
```json
{
  "error": "Missing required field: server"
}
```

### 401 Unauthorized
```json
{
  "error": "Missing X-Pdev-Token header"
}
```

or

```json
{
  "error": "Invalid server token"
}
```

### 404 Not Found
```json
{
  "error": "Session not found"
}
```

### 429 Too Many Requests
```json
{
  "error": "Too many active share tokens"
}
```

### 500 Internal Server Error
```json
{
  "error": "Database connection failed"
}
```

## Rate Limiting

| Endpoint | Limit | Window | Response |
|----------|-------|--------|----------|
| `/share-token` | 100 active tokens | N/A (in-memory) | 429 |
| Others | ⚠️ None | - | - |

**Note:** Rate limiting only implemented on `/share-token`. Other endpoints should be rate-limited in production.

## Response Time Targets

| Endpoint Type | P50 | P95 | P99 | Timeout |
|---------------|-----|-----|-----|---------|
| Simple GET | <50ms | <100ms | <200ms | 5s |
| POST (create) | <100ms | <200ms | <500ms | 10s |
| SSE connect | <100ms | <200ms | <300ms | 30s |
| Query w/ joins | <100ms | <200ms | <500ms | 10s |

## Frontend Files Using API

| File | API_BASE | Endpoints Called |
|------|----------|------------------|
| dashboard.html | `/pdev/api` | /sessions/active, /sessions/:id/complete, /sessions/:id (DELETE) |
| session.html | `/pdev/api` | /sessions/:id, /events/:sessionId, /share-token, /guest-links, /guest/:token, /manifests/:server/:project |
| live.html | `/pdev/api` | /events, /reset |
| projects.html | `/pdev` | /projects, /manifests |
| project.html | `/pdev/api` | /projects/:server/:project/sessions |
| settings.html | `/pdev` | /settings, /guest-links |

## Backend Route Definitions

**File:** `/Users/dolovdev/projects/pdev-live/server/server.js`

**Lines:**
- 362: `/contract` (GET)
- 367: `/share-token` (POST)
- 477: `/events/:sessionId` (GET SSE)
- 511: `/events` (GET SSE)
- 681: `/sessions` (POST)
- 729: `/sessions/:sessionId/steps` (POST)
- 792: `/sessions/:sessionId/complete` (POST)
- 825: `/sessions/active` (GET)
- 835: `/sessions/history` (GET)
- 849: `/sessions/find-active` (GET)
- 878: `/sessions/find-session` (GET) ⚠️ Deprecated
- 902: `/sessions/:sessionId/reopen` (POST)
- 918: `/sessions/:sessionId` (GET)
- 931: `/sessions/:sessionId/steps` (GET)
- 944: `/servers/:server/sessions` (GET)
- 964: `/sessions/:sessionId` (DELETE - admin)
- 978: `/sessions` (DELETE - admin)
- 1008: `/guest-links` (POST)
- 1081: `/project-share` (POST) - Legacy
- 1153: `/guest-links` (GET - admin)
- 1177: `/guest-links/:token` (DELETE - admin)
- 1194: `/guest/:token` (GET)
- 1222: `/update` (POST) - Legacy
- 1281: `/session` (GET) - Legacy
- 1296: `/reset` (POST - admin)
- 1338: `/version` (GET)
- 1348: `/update-file/:filename` (GET - admin)
- 1389: `/health` (GET)
- 1510: `/admin/registration-code` (POST - admin)
- 1572: `/tokens/register-with-code` (POST)
- 1719: `/tokens/register` (POST)
- 1848: `/settings` (GET - admin)
- 1885: `/settings` (POST - admin)
- 1954: `/manifests/:server/:project` (GET)
- 1985: `/manifests/:server/:project` (PUT)
- 2039: `/manifests` (GET)
- 2057: `/servers` (GET)
- 2189: `/pdev/installer/token` (POST)
- 2571: `/projects` (GET)
- 2615: `/projects/:server/:project/docs` (GET)
- 2724: `/projects/:server/:project/docs/:docType` (GET)
- 2820: `/projects/:server/:project/sessions` (GET)

## Testing

```bash
# Set environment
export PDEV_TOKEN="your-token-here"
export PDEV_ADMIN_KEY="your-admin-key"  # Optional

# Run automated tests
cd /Users/dolovdev/projects/pdev-live/tests
./validate-api.sh

# Test single endpoint
curl -s -w '\n%{http_code}\n%{time_total}\n' \
  -u "pdev:PdevLive0987@@" \
  -H "X-Pdev-Token: $PDEV_TOKEN" \
  https://walletsnack.com/pdev/api/health
```

## Documentation

- **Full Validation Report:** `API_VALIDATION_REPORT.md`
- **Layer 4 Summary:** `LAYER_4_VALIDATION_SUMMARY.md`
- **Test README:** `README.md`
- **This Reference:** `ENDPOINT_REFERENCE.md`

---

**Last Updated:** 2026-01-08
**Total Endpoints:** 37
**Status:** ✅ Production Ready
