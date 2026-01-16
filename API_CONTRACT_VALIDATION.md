# API CONTRACT VALIDATION REPORT
## PDev-Live Session-Based Authentication Endpoints

**Validation Date:** 2026-01-15
**Endpoint Status:** NEW ENDPOINTS PENDING DEPLOYMENT
**Risk Level:** HIGH (Authentication middleware affects all API endpoints)

---

## SCOPE EXPANSION SCAN RESULTS

### 1. ENDPOINT CALLER DISCOVERY

**Existing API Callers Found:**

| File | API Calls | Type | Auth Method |
|------|-----------|------|------------|
| frontend/index.html | `/reset` | POST | None (public) |
| frontend/session.html | `/sessions/:sessionId`, `/share-token`, `/guest/:token` | GET/POST | Guest token |
| frontend/projects.html | `/projects`, `/share-token` | GET/POST | None (public) |
| frontend/settings.html | `/settings`, `/guest-links`, `/health`, `/version` | GET/POST/DELETE | X-Admin-Key |
| frontend/install-wizard.html | `/pdev/installer/token` | POST | None |
| frontend/mgmt.js | `/sessions/*` | GET/POST | Various |
| frontend/version-check.js | `/health` | GET | None |
| frontend/project.html | `/contract`, `/projects/*/docs*`, `/share-token` | GET/POST | None |

**Current Authentication Patterns:**

1. **X-Admin-Key Header** - For admin operations (`/settings`, `/update-file/`, `/guest-links`)
2. **X-Pdev-Token Header** - For server/CLI webhook operations (from cache)
3. **Guest Tokens** - For session sharing via database (`/guest/:token`)
4. **Share Tokens** - Short-lived in-memory tokens for same-origin sharing
5. **No Auth** - Public endpoints: `/health`, `/contract`, `/version`, `/reset`

---

### 2. EXISTING ROUTE DEFINITIONS (Production Routes)

**Currently Deployed:**

```
PUBLIC ENDPOINTS (No auth required):
  GET  /health               - Server health check
  GET  /contract             - Document contract (API schema)
  GET  /version              - Version info
  GET  /reset                - System reset (POST)
  POST /reset                - Reset operation
  GET  /guest/:token         - Access shared session via guest token
  POST /share-token          - Generate short-lived share token

ADMIN-PROTECTED ENDPOINTS (X-Admin-Key header):
  GET  /settings             - Admin settings
  POST /settings             - Update settings
  GET  /guest-links          - List guest links
  POST /guest-links          - Create guest link
  DELETE /guest-links/:token - Revoke guest link
  GET  /update-file/:filename - Download updates

SERVER-TOKEN ENDPOINTS (X-Pdev-Token header):
  Various project/session operations

DATA ENDPOINTS (Public/Mixed):
  GET  /sessions/active      - Active sessions
  GET  /sessions/:sessionId  - Session data
  GET  /sessions/:sessionId/steps - Session steps
  POST /events/:sessionId    - SSE events
  POST /guest-links          - Create guest link
```

---

### 3. MIDDLEWARE ANALYSIS (Current Stack)

**Middleware Execution Order:**

```
1. CORS (credentials: true, allows X-Admin-Key, X-Pdev-Token, X-Share-Token)
2. Helmet.js (security headers)
3. Rate Limiter (apiLimiter - 100 req/min globally)
4. express.json() (body parsing)
5. Optional: Basic Auth (partner mode)
6. Per-route: requireAdmin() | optionalServerToken() | validateGuestToken()
```

**Current Issues Identified:**

- No global session middleware installed
- Rate limiter applied globally (affects ALL routes)
- No session-based middleware framework in place
- Guest token validation is PER-ROUTE, not global
- Middleware conflicts possible with new session middleware

---

### 4. PROPOSED NEW ENDPOINTS ANALYSIS

**NEW ENDPOINTS:**

```javascript
POST /auth/login
  Body: { username, password }
  Response: { success: true } | { error: string }
  Status: 200 (success) | 401 (invalid) | 400 (bad request)

POST /auth/logout
  Body: None
  Response: { success: true }
  Status: 200
  Side Effects: Invalidates session

GET /auth/check
  Body: None
  Response: { authenticated: boolean, loginTime: number|null }
  Status: 200 (always - never 401)
```

**NEW MIDDLEWARE: requireSession**

```javascript
Behavior:
  IF path in PUBLIC_PATHS: next()
  IF static asset (*.css, *.js, *.png): next()
  IF req.session.authenticated: next()
  IF API request (Accept: application/json): return 401 JSON
  IF HTML page request: redirect to /live/login.html
```

---

## BREAKING CHANGE ANALYSIS

### CRITICAL FINDING: Potential Breaking Changes

#### Issue 1: Global Middleware Affects All Routes

**Problem:** `requireSession` middleware inserted globally will affect ALL existing endpoints.

| Endpoint | Current Behavior | With requireSession | Impact |
|----------|-----------------|-------------------|---------|
| `/guest/:token` | Public, no auth | Requires session | BREAKING! |
| `/health` | Public, no auth | Allowed (public list) | SAFE if in whitelist |
| `/contract` | Public, no auth | Allowed (public list) | SAFE if in whitelist |
| `/settings` | X-Admin-Key header | Requires BOTH session + admin key? | CONFLICT! |
| `/share-token` | Public (same-origin) | Requires session | BREAKING! |
| Static assets | Served by nginx | Allowed (asset whitelist) | SAFE if in whitelist |

**Breaking Change Risk: HIGH**

---

#### Issue 2: Authentication Conflict - Multiple Auth Methods

**Current State:**
- X-Admin-Key for admin operations
- X-Pdev-Token for server/CLI operations
- Guest tokens for sharing
- No session-based auth

**Proposed Addition:**
- Session-based auth (login/logout/check)

**Conflict Detection:**

```
MIDDLEWARE STACK WITH SESSION:
Layer 1: Global requireSession middleware
  -> Checks: authenticated flag in req.session
  -> Allows: public paths, static files
  -> Blocks: API endpoints without session

Layer 2: Per-route requireAdmin (X-Admin-Key)
  -> Checks: X-Admin-Key header

CONFLICT: Admin endpoints require BOTH session AND X-Admin-Key?
  OR: Admin endpoints bypass session requirement?
  OR: Admin login via /auth/login endpoint?
```

**Risk Assessment: CRITICAL**

Clarification needed:
- [ ] Do admin operations require session auth + X-Admin-Key?
- [ ] Can admin key bypass session requirement?
- [ ] Are CLI operations (X-Pdev-Token) affected by session middleware?

---

#### Issue 3: Client-Side Breaking Changes

**Frontend currently uses:**
```javascript
// No session check before API calls
fetch('/api/endpoint', { method: 'POST' })

// No cookie handling
// No CSRF tokens
// No session-aware error handling
```

**After session middleware:**
```javascript
// Frontend will start receiving 401 responses
// Frontend needs to redirect to login
// Frontend needs to handle 302 redirects in API calls
// Credentials mode needs updating
```

**Breaking Change: YES - Frontend must add session handling**

---

#### Issue 4: Guest Token and Share Token Conflicts

**Current behavior:**
- `/guest/:token` - Public endpoint, no session required
- `/share-token` - Public endpoint, returns token to same-origin

**With requireSession middleware:**
```
GET /guest/:token
  -> Hits requireSession middleware
  -> User not authenticated (no session)
  -> Middleware redirects to /live/login.html
  -> BROKEN: Guest links stop working!
```

**Breaking Change: YES - Guest sharing breaks**

---

## COMPATIBILITY CLASSIFICATION

### Category 1: BREAKING CHANGES (Major Version Required)

1. **Guest endpoint loses public access** - `/guest/:token`
   - Current: Public, no auth
   - Proposed: Protected by session middleware
   - Impact: Guest link sharing stops working
   - Fix Required: Whitelist `/guest/*` in middleware

2. **Share token endpoint may break** - `/share-token`
   - Current: Public same-origin
   - Proposed: Protected by session middleware
   - Impact: Frontend can't get share tokens
   - Fix Required: Keep public OR require frontend to authenticate first

3. **Frontend requires session handling**
   - Current: No session awareness
   - Proposed: Must handle session checks and redirects
   - Impact: Frontend breaks on 401/302 responses
   - Fix Required: Update all API calls with session error handling

4. **Admin endpoints ambiguity** - `/settings`, `/guest-links`, etc.
   - Current: Protected by X-Admin-Key header
   - Proposed: Unclear if session + key or just key required
   - Impact: API contract undefined
   - Fix Required: Document authentication flow clearly

5. **CLI operations (X-Pdev-Token) blocked?**
   - Current: Server-to-server webhook operations
   - Proposed: Unclear if affected by session middleware
   - Impact: Webhooks may fail to authenticate
   - Fix Required: Whitelist X-Pdev-Token in middleware bypass

---

### Category 2: REQUIRED CLARIFICATIONS

**MUST BE DEFINED BEFORE DEPLOYMENT:**

1. Public Paths Whitelist:
   - [ ] Define exact paths that bypass session requirement
   - [ ] `/guest/*` - should this be public?
   - [ ] `/share-token` - should this be public?
   - [ ] `/auth/*` - obviously public
   - [ ] `/health` - health checks (public)
   - [ ] `/contract` - API schema (public)
   - [ ] `/version` - version info (public)

2. Admin Authentication Strategy:
   - [ ] Do admins need to login via `/auth/login`?
   - [ ] Can X-Admin-Key bypass session requirement?
   - [ ] Or: X-Admin-Key verified AFTER session check?
   - [ ] How to prevent unauthorized users from attempting admin operations?

3. Server Token (X-Pdev-Token) Handling:
   - [ ] Should CLI webhooks bypass session?
   - [ ] Or should server tokens require session + token?
   - [ ] Impact on automation/deployment workflows?

4. Frontend Session Strategy:
   - [ ] How does frontend handle 401 Unauthorized?
   - [ ] How does frontend handle 302 redirect to login?
   - [ ] Should fetch use `credentials: 'include'`?
   - [ ] How to detect "not authenticated" and show login page?

5. Guest/Share Token Flow:
   - [ ] Guest links = public OR requires viewer authentication?
   - [ ] Share tokens = public OR requires sharer authentication?
   - [ ] If public: must whitelist in middleware
   - [ ] If private: UX changes needed for guests

---

## RESPONSE SCHEMA VALIDATION

### Endpoint 1: POST /auth/login

**Proposed Schema:**
```json
SUCCESS (200):
{
  "success": true
}

ERROR - Missing Fields (400):
{
  "error": "username and password required"
}

ERROR - Invalid Credentials (401):
{
  "error": "Invalid username or password"
}
```

**Issues Identified:**

1. **Ambiguous Success Response**
   - Returns minimal data
   - Frontend doesn't know: username, user ID, permissions, admin status
   - Session created in background (cookie)
   - But no way to confirm from response

2. **No Session Token in Response**
   - Relies on HTTP cookies
   - Cookies must be: HttpOnly, Secure, SameSite=Strict
   - No explicit token for header-based auth
   - CLI clients may not handle cookies correctly

3. **Missing Error Details**
   - No error codes (only strings)
   - Can't distinguish: network error vs auth error
   - Can't implement retry logic

**Recommendation:**

```json
SUCCESS (200):
{
  "success": true,
  "user": {
    "username": "admin",
    "isAdmin": true,
    "loginTime": 1705324800000
  },
  "session": {
    "expiresAt": 1705328400000,
    "expiresIn": 3600
  }
}

ERROR (401):
{
  "error": "Invalid credentials",
  "errorCode": "INVALID_LOGIN",
  "timestamp": "2026-01-15T12:00:00Z"
}
```

---

### Endpoint 2: POST /auth/logout

**Proposed Schema:**
```json
SUCCESS (200):
{
  "success": true
}

ERROR (500):
{
  "error": "Logout failed"
}
```

**Issues Identified:**

1. **No logout verification**
   - Response doesn't confirm session invalidated
   - Frontend doesn't know if logout succeeded
   - Client might still have valid session cookie

2. **Logout can't fail**
   - Error response seems wrong
   - Should be 200 even if already logged out
   - Idempotent operation expected

**Recommendation:**

```json
SUCCESS (200):
{
  "success": true,
  "message": "Session terminated"
}
```

---

### Endpoint 3: GET /auth/check

**Proposed Schema:**
```json
{
  "authenticated": true,
  "loginTime": 1705324800000
}

OR (not authenticated):
{
  "authenticated": false,
  "loginTime": null
}
```

**Issues Identified:**

1. **Good backward compatibility**
   - No error responses (always 200)
   - Doesn't force frontend into error handling
   - Simple boolean check works

2. **Missing information**
   - No user info (username, permissions)
   - No session expiry info
   - No way to know remaining time until expiry

**Recommendation:**

```json
{
  "authenticated": true,
  "username": "admin",
  "isAdmin": true,
  "loginTime": 1705324800000,
  "expiresAt": 1705328400000,
  "expiresIn": 3600
}

OR (not authenticated):
{
  "authenticated": false,
  "username": null,
  "loginTime": null,
  "expiresAt": null,
  "expiresIn": null
}
```

---

## MIDDLEWARE CONFLICT DETECTION

### Conflict 1: Global Session Middleware + Per-Route Auth

**Current Pattern:**
```javascript
// Per-route auth
app.get('/guest-links', requireAdmin, async (req, res) => {
  // requireAdmin checks X-Admin-Key header
})
```

**With Global Session Middleware:**
```javascript
// Global middleware fires first
app.use((req, res, next) => {
  if (!req.session.authenticated) {
    // Redirect or 401
  }
})

// Then per-route middleware
app.get('/settings', requireAdmin, async (req, res) => {
  // By now, middleware already ran!
})
```

**Conflict: Order matters!**

Need to clarify:
- [ ] Can requireAdmin bypass session check?
- [ ] Or must admin first authenticate via /auth/login?

---

### Conflict 2: Redirect vs JSON Response

**Middleware behavior for different client types:**

```javascript
// HTML page request
GET /settings (Accept: text/html)
  -> No session
  -> Middleware redirects to /live/login.html
  -> Browser follows redirect
  -> User sees login form
  -> GOOD UX

// API request from frontend JS
fetch('/api/settings')
  -> No session
  -> Middleware redirects to /live/login.html
  -> fetch doesn't follow redirect by default
  -> Frontend receives /live/login.html as body
  -> Frontend JS fails to parse JSON
  -> BROKEN!

// CLI request
curl /settings -H "X-Admin-Key: ..."
  -> No session
  -> Middleware redirects to /live/login.html
  -> curl follows redirect
  -> Receives login HTML instead of 401
  -> BROKEN!
```

**Conflict: Content negotiation required**

Need to:
- [ ] Detect request type (Accept header)
- [ ] Return JSON for API requests
- [ ] Return HTML redirect for page requests
- [ ] Return JSON error for CLI clients

---

### Conflict 3: Static File Serving

**Current:**
```javascript
app.use(express.static(FRONTEND_DIR, staticOptions))
app.use('/live', express.static(FRONTEND_DIR, staticOptions))
```

**With requireSession middleware:**
```
GET /style.css
  -> Hits requireSession
  -> Not authenticated
  -> Returns 401 or redirects
  -> Browser can't load stylesheet!
  -> Page renders unstyled
```

**Conflict: Static files must bypass middleware**

**Solution:** Whitelist static file extensions in middleware

---

## OPENAPI SPECIFICATION VALIDATION

### Current API Documentation

**EXISTING ENDPOINTS (should validate existing contract):**

Check if `/contract` endpoint defines all current APIs:
- Does it list all endpoints?
- Do response schemas match actual responses?
- Are all parameters documented?

**NEW ENDPOINTS (must be added to contract):**

Add to `/contract`:
```json
{
  "/auth/login": {
    "post": {
      "summary": "Login with username and password",
      "requestBody": {
        "username": "string",
        "password": "string"
      },
      "responses": {
        "200": { "success": true },
        "401": { "error": "string" }
      }
    }
  },
  "/auth/logout": {
    "post": {
      "summary": "Logout and invalidate session",
      "responses": {
        "200": { "success": true }
      }
    }
  },
  "/auth/check": {
    "get": {
      "summary": "Check authentication status",
      "responses": {
        "200": {
          "authenticated": "boolean",
          "loginTime": "number|null"
        }
      }
    }
  }
}
```

---

## SECURITY VALIDATION

### 1. Authentication Method
- [ ] Username/password with hashing (bcrypt required)
- [ ] Session storage location (PostgreSQL, in-memory, redis?)
- [ ] Session ID generation (crypto.randomBytes)
- [ ] Session expiry time (default 1 hour?)
- [ ] Secure cookie settings (HttpOnly, Secure, SameSite)

### 2. Password Storage
- ❌ NEVER store plaintext passwords
- ✅ REQUIRED: bcrypt hashing
- ✅ REQUIRED: Salt rounds >= 10
- ✅ REQUIRED: Timing-safe comparison

### 3. CSRF Protection
- [ ] Is CSRF token needed?
- [ ] Are POST endpoints (login, logout) protected?
- [ ] Session-based cookie requires CSRF token

### 4. Session Hijacking Prevention
- [ ] HttpOnly cookie flag (prevent JS access)
- [ ] Secure flag (HTTPS only)
- [ ] SameSite=Strict (prevent CSRF)
- [ ] Session rotation after login
- [ ] Token binding to IP? (optional, may break mobile)

### 5. Brute Force Protection
- [ ] Rate limit on `/auth/login`
- [ ] Lock account after N failures?
- [ ] Progressive delays?

### 6. Session Fixation
- [ ] Generate new session ID after login
- [ ] Invalidate old session

---

## TESTING VALIDATION

### Must-Have Contract Tests

**Test Suite 1: Login Flow**
```javascript
1. POST /auth/login with valid credentials
   -> Status 200
   -> { success: true }
   -> Session cookie set

2. POST /auth/login with invalid username
   -> Status 401
   -> { error: "..." }
   -> No session cookie

3. POST /auth/login with wrong password
   -> Status 401
   -> { error: "..." }
   -> No session cookie

4. POST /auth/login missing username
   -> Status 400
   -> { error: "..." }
```

**Test Suite 2: Session Check**
```javascript
1. GET /auth/check without authentication
   -> Status 200
   -> { authenticated: false, loginTime: null }

2. GET /auth/check after login
   -> Status 200
   -> { authenticated: true, loginTime: <number> }
```

**Test Suite 3: Logout Flow**
```javascript
1. POST /auth/logout after login
   -> Status 200
   -> { success: true }
   -> Session invalidated

2. GET /auth/check after logout
   -> Status 200
   -> { authenticated: false }
```

**Test Suite 4: Session Persistence**
```javascript
1. Login
2. Call /guest/:token with same session
   -> Should work (if guest is public)

3. Call /settings (admin) without X-Admin-Key but with session
   -> Should fail (requires BOTH)
```

**Test Suite 5: Protected Endpoints**
```javascript
1. GET /guest/:token without session
   -> Should work (guest is public) OR fail?
   -> MUST BE TESTED

2. GET /settings without session or key
   -> Status 401 or 302 redirect

3. GET /health without session
   -> Status 200 (public endpoint)
```

---

## BACKWARD COMPATIBILITY MATRIX

| Endpoint | Current Behavior | With New Middleware | Compatible? | Action |
|----------|-----------------|-------------------|------------|--------|
| `/health` | Public | Public (whitelist) | YES | Whitelist in requireSession |
| `/contract` | Public | Public (whitelist) | YES | Whitelist in requireSession |
| `/version` | Public | Public (whitelist) | YES | Whitelist in requireSession |
| `/guest/:token` | Public | Session required? | BREAKING | Clarify: public or private? |
| `/share-token` | Public | Session required? | BREAKING | Clarify: public or private? |
| `/reset` | Public | Session required? | BREAKING | Whitelist or require auth? |
| `/settings` (GET) | X-Admin-Key | X-Admin-Key + Session? | BREAKING | Clarify: both or either? |
| `/guest-links` (GET) | X-Admin-Key | X-Admin-Key + Session? | BREAKING | Clarify: both or either? |
| `/sessions/:id` | Public | Session required? | BREAKING | Clarify: authentication logic |
| `*.css, *.js, *.png` | Served static | Allowed (static list) | YES | Whitelist file extensions |
| CLI with X-Pdev-Token | Works | Session blocks? | BREAKING? | Whitelist X-Pdev-Token |

---

## DEPLOYMENT RISK ASSESSMENT

| Risk Factor | Severity | Issue | Mitigation |
|------------|----------|-------|-----------|
| Breaking Guest Links | CRITICAL | Public access lost | Whitelist `/guest/*` |
| Admin Auth Unclear | CRITICAL | API contract undefined | Document auth strategy |
| Frontend Incompatible | HIGH | No session handling | Update frontend code |
| Static Files Broken | HIGH | Stylesheet 401 errors | Whitelist static extensions |
| CLI Webhooks Blocked | HIGH | Automation fails | Whitelist X-Pdev-Token |
| Cookie Handling | MEDIUM | Partner deployments | Document cookie config |
| CORS with Cookies | MEDIUM | Credentials mode | Verify CORS settings |
| Session Storage | MEDIUM | Database sizing | Plan PostgreSQL cleanup |

---

## VALIDATION SIGN-OFF CHECKLIST

**BLOCKING ISSUES (Must resolve before deployment):**

- [ ] **Define Public Paths Whitelist** - Exactly which paths bypass session?
- [ ] **Define Admin Auth Strategy** - Do admins login or use X-Admin-Key only?
- [ ] **Define Guest/Share Access** - Public or private?
- [ ] **Update Frontend Code** - Add session error handling
- [ ] **Implement CSRF Protection** - Session-based auth requires CSRF
- [ ] **Implement Brute Force Protection** - Rate limiting on /auth/login
- [ ] **Document Cookie Settings** - HttpOnly, Secure, SameSite
- [ ] **Test with CLI Clients** - X-Pdev-Token interactions
- [ ] **Verify CORS Credentials** - credentials: 'include' compatibility
- [ ] **Create Migration Plan** - How to handle existing authenticated users?

**WARNINGS (Should resolve before production):**

- [ ] Response schemas incomplete (missing user info)
- [ ] No session expiry endpoint documented
- [ ] No password change endpoint documented
- [ ] No account lockout mechanism documented
- [ ] No audit logging documented
- [ ] Session storage strategy not documented

**RECOMMENDED IMPROVEMENTS:**

1. Add user info to login response
2. Add session expiry info to /auth/check
3. Add password change endpoint: POST /auth/change-password
4. Add account management endpoint: GET /auth/me
5. Add session invalidation endpoint: DELETE /auth/sessions/:id
6. Add audit logging for auth events
7. Implement account lockout after 5 failed attempts
8. Implement rate limiting (5 login attempts per minute per IP)

---

## CONCLUSION

**VALIDATION STATUS: BLOCKED - CLARIFICATION REQUIRED**

The proposed session-based authentication endpoints cannot be validated as "backward compatible" without clarifying the following critical architectural decisions:

1. **Public vs. Private Paths** - Exact whitelist definition needed
2. **Admin Authentication Flow** - Session + key vs. key-only
3. **Guest/Share Token Access** - Public or requires authentication
4. **CLI Impact** - X-Pdev-Token interaction with session middleware
5. **Frontend Changes** - Session error handling requirements

**Recommended Actions:**

1. **DOCUMENT** authentication architecture decisions
2. **IDENTIFY** all breaking changes (use matrix above)
3. **IMPLEMENT** migration strategy for existing clients
4. **TEST** backward compatibility with contract tests
5. **DEPLOY** to staging environment first
6. **VALIDATE** with production-like load testing

**Risk Level Without Clarification: CRITICAL**

The current proposal has potential to break:
- Guest link sharing (public access removed)
- Admin operations (authentication flow unclear)
- CLI integrations (webhooks may fail)
- Frontend functionality (no session handling code)
- Static asset loading (CSS/JS 401 errors)

**Next Steps:**

- [ ] Review this report with team
- [ ] Resolve all clarification questions
- [ ] Update API contract documentation
- [ ] Implement required tests
- [ ] Run full integration test suite
- [ ] Deploy to staging first
- [ ] Monitor production for breaking changes
