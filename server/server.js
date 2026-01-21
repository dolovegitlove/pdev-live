/**
 * PDev Live Mirror Server v2
 * Multi-server session tracking with PostgreSQL persistence
 *
 * Architecture:
 * - Webhook API receives updates from all configured servers (see VALID_SERVERS in config)
 * - PostgreSQL stores sessions and steps with UUID-based routing
 * - SSE broadcasts to connected browsers (session-specific channels)
 * - Markdown rendered server-side for consistent display
 */

require('dotenv').config();

const express = require('express');
const cors = require('cors');
const helmet = require('helmet');
const path = require('path');
const http = require('http');
const crypto = require('crypto');
const { marked } = require('marked');
const hljs = require('highlight.js');
const { Pool } = require('pg');
const WebSocket = require('ws');
const { Client } = require('ssh2');
const validator = require('validator');
const createDOMPurify = require('dompurify');
const { JSDOM } = require('jsdom');
const session = require('express-session');
const config = require('../config');

// DOMPurify setup for server-side sanitization
const window = new JSDOM('').window;
const DOMPurify = createDOMPurify(window);

const app = express();
app.set('trust proxy', 1); // Trust nginx reverse proxy for X-Forwarded-For
const server = http.createServer(app);
const PORT = config.api.port;

// ============================================================================
// BASE URL CONFIGURATION
// ============================================================================
const PDEV_BASE_URL_RAW = process.env.PDEV_BASE_URL || `http://localhost:${PORT}`;
const PDEV_BASE_URL = PDEV_BASE_URL_RAW.replace(/\/$/, ''); // Remove trailing slash

// Validate URL format
try {
  new URL(PDEV_BASE_URL);
} catch (err) {
  console.error('FATAL: PDEV_BASE_URL invalid format:', PDEV_BASE_URL);
  console.error('Expected: http(s)://domain.com or http(s)://domain.com/path');
  console.error('Error:', err.message);
  process.exit(1);
}

// Production validation
if (process.env.NODE_ENV === 'production') {
  if (!process.env.PDEV_BASE_URL) {
    console.error('🔴 FATAL: PDEV_BASE_URL required in production');
    console.error('Set: export PDEV_BASE_URL=https://your-domain.com');
    process.exit(1);
  }

  if (!PDEV_BASE_URL.startsWith('https://')) {
    console.error('🔴 FATAL: PDEV_BASE_URL must use HTTPS in production');
    console.error('Current:', PDEV_BASE_URL);
    process.exit(1);
  }
}

// PostgreSQL connection pool
const pool = new Pool({
  host: process.env.PDEV_DB_HOST || 'localhost',
  port: parseInt(process.env.PDEV_DB_PORT || '5432', 10),
  database: process.env.PDEV_DB_NAME || 'pdev_live',
  user: process.env.PDEV_DB_USER || 'pdev_app',
  password: (() => {
    const dbPassword = process.env.PDEV_DB_PASSWORD;
    if (!dbPassword) {
      console.error('FATAL: PDEV_DB_PASSWORD required');
      process.exit(1);
    }
    if (dbPassword.length < 16) {
      console.error('FATAL: PDEV_DB_PASSWORD must be at least 16 characters');
      console.error('Generate with: openssl rand -base64 24');
      process.exit(1);
    }
    return dbPassword;
  })(),
  max: 20,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 10000,  // Increased from 2000ms to 10000ms (10 seconds)
  statement_timeout: 30000,         // Kill queries after 30 seconds
  query_timeout: 30000              // Client-side query timeout
});

// Connection pool error handlers
pool.on('error', (err, client) => {
  console.error('Unexpected database error on idle client', err);
  // Don't exit - log error and continue with remaining connections
});

pool.on('connect', (client) => {
  console.log('Database connection established');
});

pool.on('remove', (client) => {
  console.log('Database connection removed from pool');
});

// Connection leak detection (every 30 seconds)
setInterval(() => {
  const totalConns = pool.totalCount;
  const idleConns = pool.idleCount;
  const waitingConns = pool.waitingCount;

  // Warn if > 90% pool utilization
  if (totalConns >= 18) {
    console.warn('[POOL] High connection usage:', {
      total: totalConns,
      idle: idleConns,
      waiting: waitingConns,
      active: totalConns - idleConns
    });
  }

  // Critical if waiting requests
  if (waitingConns > 0) {
    console.error('[POOL] Connection pool exhausted! Waiting requests:', waitingConns);
  }
}, 30000);

// Configure marked for syntax highlighting
marked.setOptions({
  highlight: function(code, lang) {
    if (lang && hljs.getLanguage(lang)) {
      try {
        return hljs.highlight(code, { language: lang }).value;
      } catch (e) {}
    }
    return hljs.highlightAuto(code).value;
  },
  breaks: true,
  gfm: true
});

// Store connected SSE clients by session ID
// Map<sessionId, Set<response>>
const sessionClients = new Map();

// SINGLE SOURCE OF TRUTH: Load doc contract from JSON file
// Both backend (normalization) and frontend (PIPELINE_DOCS) use this
const fs = require('fs');
const DOC_CONTRACT_PATH = path.join(__dirname, 'doc-contract.json');
let DOC_CONTRACT = { PIPELINE_DOCS: [] };
try {
  DOC_CONTRACT = JSON.parse(fs.readFileSync(DOC_CONTRACT_PATH, 'utf8'));
  console.log(`[PDev Live v2] Loaded doc contract: ${DOC_CONTRACT.PIPELINE_DOCS.length} document types`);
} catch (e) {
  console.error('[PDev Live v2] Failed to load doc-contract.json, using defaults');
}

// Build normalization map from contract (aliases -> canonical type)
const DOC_TYPE_NORMALIZATION = {};
DOC_CONTRACT.PIPELINE_DOCS.forEach(doc => {
  (doc.aliases || []).forEach(alias => {
    DOC_TYPE_NORMALIZATION[alias] = doc.type;
  });
});

// Normalize document type to canonical form
function normalizeDocType(docType) {
  const upper = docType.toUpperCase().replace(/\.MD$/i, '').trim();
  return DOC_TYPE_NORMALIZATION[upper] || upper;
}
// Global clients (watching all sessions)
const globalClients = new Set();

// PDev commands to track
const PDEV_COMMANDS = [
  '/pdev', '/idea', '/ideate', '/eval', '/bmrk', '/gapa',
  '/innov', '/caps', '/spec', '/sop', '/pv', '/pdev-regen'
];

// Valid server origins (from config)
const VALID_SERVERS = config.servers.valid;

// Session idempotency cache - prevents duplicate session creation on double-submit
const recentSessionRequests = new Map(); // key: hash, value: { sessionId, timestamp }
const IDEMPOTENCY_WINDOW_MS = 5000; // 5 second dedup window
const MAX_IDEMPOTENCY_KEYS = 10000; // Prevent memory exhaustion attacks

// Cleanup stale idempotency entries every 5 seconds (matches TTL for efficient cleanup)
const idempotencyCleanupInterval = setInterval(() => {
  const now = Date.now();
  for (const [key, entry] of recentSessionRequests) {
    if (now - entry.timestamp > IDEMPOTENCY_WINDOW_MS) {
      recentSessionRequests.delete(key);
    }
  }
}, 5000);

// Ensure cleanup stops on server shutdown
process.on('SIGTERM', () => clearInterval(idempotencyCleanupInterval));
process.on('SIGINT', () => clearInterval(idempotencyCleanupInterval));

// Frontend directory for auto-update (environment-specific)
const FRONTEND_DIR = process.env.PDEV_FRONTEND_DIR || path.join(__dirname, '..', 'frontend');

// Admin key for protected operations (REQUIRED)
const ADMIN_KEY = process.env.PDEV_ADMIN_KEY;
if (!ADMIN_KEY || ADMIN_KEY.length < 32) {
  console.error('FATAL: PDEV_ADMIN_KEY must be set (min 32 chars)');
  console.error('Generate with: openssl rand -base64 32');
  process.exit(1);
}

// Guest link tokens (in-memory with cleanup)
// Guest tokens now persisted in database (guest_tokens table)
const MAX_GUEST_TOKENS = 1000;

// Short-lived share tokens (in-memory, 5 minute expiry)
const shareTokens = new Map(); // token -> { expiresAt, used }
const MAX_SHARE_TOKENS = 100;

// Server tokens cache (loaded from DB, refreshed periodically)
// Maps token -> { server, createdAt }
let serverTokensCache = new Map();
async function loadServerTokens() {
  try {
    const result = await pool.query(
      'SELECT token, server_name, created_at FROM server_tokens WHERE revoked_at IS NULL'
    );
    serverTokensCache = new Map();
    result.rows.forEach(row => {
      serverTokensCache.set(row.token, {
        server: row.server_name,
        createdAt: row.created_at
      });
    });
    console.log(`[Auth] Loaded ${serverTokensCache.size} server tokens`);
  } catch (err) {
    // Table may not exist yet - that's OK
    if (err.code !== '42P01') { // relation does not exist
      console.error('[Auth] Failed to load server tokens:', err.message);
    }
  }
}
// Refresh tokens every 5 minutes
setInterval(loadServerTokens, 5 * 60 * 1000);

// Cleanup expired tokens every minute
const cleanupInterval = setInterval(async () => {
  try {
    // Cleanup expired guest tokens from database
    const result = await pool.query(
      'DELETE FROM guest_tokens WHERE expires_at <= NOW() RETURNING token'
    );

    if (result.rowCount > 0) {
      console.log(`[TOKEN] Cleaned up ${result.rowCount} expired guest token(s)`);
    }

    // Cleanup share tokens (still in-memory, 5-minute expiry)
    const now = Date.now();
    for (const [token, data] of shareTokens.entries()) {
      if (now > data.expiresAt || data.used) {
        shareTokens.delete(token);
      }
    }
  } catch (err) {
    console.error('[TOKEN] Cleanup error:', err);
  }
}, 60000);

// Graceful shutdown
process.on('SIGTERM', async () => {
  console.log('SIGTERM received, closing database connections...');
  clearInterval(cleanupInterval);
  await pool.end();
  process.exit(0);
});

// CORS configuration - strict origin validation
// Parse BASE_URL for secure CORS construction (origin only, no pathname)
const baseUrlObj = new URL(PDEV_BASE_URL);
const protocol = baseUrlObj.protocol; // 'https:'
const hostname = baseUrlObj.hostname; // 'vyxenai.com' or 'partner-company.com'
const port = baseUrlObj.port; // '' or '3077'

const baseOrigin = `${protocol}//${hostname}${port ? ':' + port : ''}`;
const wwwOrigin = hostname.startsWith('www.')
  ? null
  : `${protocol}//www.${hostname}${port ? ':' + port : ''}`;

const ALLOWED_ORIGINS = [
  baseOrigin,
  wwwOrigin,
  `http://localhost:${PORT}`,
  `http://127.0.0.1:${PORT}`,
  `http://[::1]:${PORT}` // IPv6 localhost
].filter(Boolean).filter((v, i, a) => a.indexOf(v) === i); // Deduplicate

app.use(cors({
  origin: function(origin, callback) {
    // Allow requests with no origin (like mobile apps, curl, or same-origin)
    if (!origin) return callback(null, true);
    if (ALLOWED_ORIGINS.includes(origin)) {
      return callback(null, true);
    }
    console.warn('[CORS] Blocked origin:', origin);
    return callback(new Error('Not allowed by CORS'));
  },
  credentials: true,
  methods: ['GET', 'POST', 'PUT', 'PATCH', 'DELETE', 'OPTIONS'],
  allowedHeaders: ['Content-Type', 'X-Admin-Key', 'X-Share-Token', 'X-User', 'X-Pdev-Token']
}));

// Security headers (Helmet.js)
app.use(helmet({
  contentSecurityPolicy: {
    directives: {
      defaultSrc: ["'self'"],
      scriptSrc: ["'self'", "'unsafe-inline'", "https://cdnjs.cloudflare.com"],
      styleSrc: ["'self'", "'unsafe-inline'", "https://cdnjs.cloudflare.com"],
      imgSrc: ["'self'", "data:", "https:"],
      connectSrc: ["'self'", "https://cdnjs.cloudflare.com"],
      fontSrc: ["'self'"],
      objectSrc: ["'none'"],
      mediaSrc: ["'self'"],
      frameSrc: ["'none'"]
    }
  },
  hsts: {
    maxAge: 31536000,
    includeSubDomains: true,
    preload: true
  },
  frameguard: { action: 'deny' },
  xssFilter: true,
  noSniff: true
}));

// Rate limiting
const rateLimit = require('express-rate-limit');
const apiLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: 100,
  message: { error: 'Rate limit exceeded' },
  standardHeaders: true,
  legacyHeaders: false
});
const mutationLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: 30,
  message: { error: 'Mutation rate limit exceeded' }
});

app.use(apiLimiter);
app.use(express.json({ limit: '10mb' }));

// ============================================================================
// PARAMETER NORMALIZATION MIDDLEWARE
// ============================================================================
// Backward compatibility: Accept both old (server_origin/project_name) and new (server/project) parameters
// Normalize to new standard while logging deprecation warnings
app.use((req, res, next) => {
  // Query parameters
  if (req.query.server_origin && !req.query.server) {
    // Sanitize before normalization (alphanumeric, hyphens, underscores only)
    if (!/^[a-zA-Z0-9_-]+$/.test(req.query.server_origin)) {
      return res.status(400).json({ error: 'Invalid server_origin format' });
    }
    req.query.server = req.query.server_origin;
    console.warn(`[DEPRECATION] Use 'server' instead of 'server_origin' in query params. Route: ${req.path}`);
  }
  if (req.query.project_name && !req.query.project) {
    // Sanitize before normalization (alphanumeric, hyphens, underscores only)
    if (!/^[a-zA-Z0-9_-]+$/.test(req.query.project_name)) {
      return res.status(400).json({ error: 'Invalid project_name format' });
    }
    req.query.project = req.query.project_name;
    console.warn(`[DEPRECATION] Use 'project' instead of 'project_name' in query params. Route: ${req.path}`);
  }

  // Body parameters
  if (req.body?.server_origin && !req.body.server) {
    // Sanitize before normalization
    if (!/^[a-zA-Z0-9_-]+$/.test(req.body.server_origin)) {
      return res.status(400).json({ error: 'Invalid server_origin format' });
    }
    req.body.server = req.body.server_origin;
    console.warn(`[DEPRECATION] Use 'server' instead of 'server_origin' in body. Route: ${req.path}`);
  }
  if (req.body?.project_name && !req.body.project) {
    // Sanitize before normalization
    if (!/^[a-zA-Z0-9_-]+$/.test(req.body.project_name)) {
      return res.status(400).json({ error: 'Invalid project_name format' });
    }
    req.body.project = req.body.project_name;
    console.warn(`[DEPRECATION] Use 'project' instead of 'project_name' in body. Route: ${req.path}`);
  }

  next();
});

// ============================================================================
// SESSION-BASED AUTHENTICATION
// ============================================================================
// Cookie-based session auth for browser/web UI access
// Replaces HTTP Basic Auth for better UX (no repeated password prompts)
// Coexists with: X-Admin-Key (admin ops), X-Pdev-Token (CLI), Guest tokens
// NOTE: Session middleware MUST come BEFORE static file serving to protect HTML pages

const SESSION_SECRET = process.env.PDEV_SESSION_SECRET;
if (!SESSION_SECRET || SESSION_SECRET.length < 32) {
  console.error('FATAL: PDEV_SESSION_SECRET must be at least 32 characters');
  console.error('Generate with: openssl rand -hex 32');
  process.exit(1);
}

app.use(session({
  secret: SESSION_SECRET,
  name: 'pdev.sid',
  resave: false,
  saveUninitialized: false,
  cookie: {
    secure: process.env.NODE_ENV === 'production',
    httpOnly: true,
    sameSite: 'strict',
    maxAge: 30 * 24 * 60 * 60 * 1000 // 30 days
  }
}));

// Rate limiter for login endpoint (5 attempts per 15 minutes)
const loginLimiter = rateLimit({
  windowMs: 15 * 60 * 1000,
  max: 5,
  message: { error: 'Too many login attempts, try again later' },
  standardHeaders: true,
  legacyHeaders: false
});

// Login endpoint
app.post('/auth/login', loginLimiter, (req, res) => {
  const { username, password } = req.body;

  // Input validation
  if (typeof username !== 'string' || typeof password !== 'string') {
    return res.status(400).json({ error: 'Invalid request format' });
  }
  if (username.length > 100 || password.length > 200) {
    return res.status(400).json({ error: 'Invalid credentials' });
  }

  const validUser = process.env.PDEV_USERNAME;
  const validPass = process.env.PDEV_PASSWORD;

  if (!validUser || !validPass) {
    console.error('[AUTH] PDEV_USERNAME or PDEV_PASSWORD not configured');
    return res.status(500).json({ error: 'Auth not configured' });
  }

  // Timing-safe comparison for BOTH username and password
  const usernameBuffer = Buffer.from(String(username));
  const validUserBuffer = Buffer.from(String(validUser));
  const passwordBuffer = Buffer.from(String(password));
  const validPassBuffer = Buffer.from(String(validPass));

  const maxUserLen = Math.max(usernameBuffer.length, validUserBuffer.length);
  const maxPassLen = Math.max(passwordBuffer.length, validPassBuffer.length);

  const paddedUsername = Buffer.alloc(maxUserLen);
  const paddedValidUser = Buffer.alloc(maxUserLen);
  const paddedPassword = Buffer.alloc(maxPassLen);
  const paddedValidPass = Buffer.alloc(maxPassLen);

  usernameBuffer.copy(paddedUsername);
  validUserBuffer.copy(paddedValidUser);
  passwordBuffer.copy(paddedPassword);
  validPassBuffer.copy(paddedValidPass);

  const userMatch = crypto.timingSafeEqual(paddedUsername, paddedValidUser);
  const passMatch = crypto.timingSafeEqual(paddedPassword, paddedValidPass);
  const lengthMatch = usernameBuffer.length === validUserBuffer.length &&
                      passwordBuffer.length === validPassBuffer.length;

  if (userMatch && passMatch && lengthMatch) {
    req.session.regenerate((err) => {
      if (err) {
        console.error('[AUTH] Session regenerate error:', err);
        return res.status(500).json({ error: 'Session error' });
      }
      req.session.authenticated = true;
      req.session.loginTime = Date.now();
      req.session.save((err) => {
        if (err) {
          console.error('[AUTH] Session save error:', err);
          return res.status(500).json({ error: 'Session error' });
        }
        console.log('[AUTH] Login successful for user:', username);
        res.json({ success: true });
      });
    });
  } else {
    console.log('[AUTH] Login failed for user:', username);
    res.status(401).json({ error: 'Invalid credentials' });
  }
});

// Logout endpoint
app.post('/auth/logout', (req, res) => {
  const sessionId = req.session.id;
  req.session.destroy((err) => {
    if (err) {
      console.error('[AUTH] Session destroy error:', err);
    }
    res.clearCookie('pdev.sid', {
      secure: process.env.NODE_ENV === 'production',
      httpOnly: true,
      sameSite: 'strict'
    });
    console.log('[AUTH] Logout for session:', sessionId);
    res.json({ success: true });
  });
});

// Auth check endpoint
app.get('/auth/check', (req, res) => {
  res.json({
    authenticated: !!req.session.authenticated,
    loginTime: req.session.loginTime || null
  });
});

// Auto-authenticate session for HTTP Basic Auth users (nginx layer)
// This allows users who pass nginx Basic Auth to access API endpoints
// SECURITY: Only trusts requests with X-Pdev-Nginx-Auth header (set by nginx AFTER Basic Auth passes)
app.use((req, res, next) => {
  // Skip if already authenticated (avoid re-processing)
  if (req.session.authenticated) {
    return next();
  }

  // Skip for public paths that don't need auth
  const publicPaths = [
    '/auth/login', '/auth/logout', '/auth/check',
    '/health', '/guest/', '/contract', '/version',
    '/pdev/installer', '/webssh', 
  ];
  if (typeof req.path === 'string' && publicPaths.some(p => req.path.startsWith(p))) {
    return next();
  }

  // Skip for static assets
  if (req.path.match(/\.(css|js|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$/)) {
    return next();
  }

  // SECURE: Auto-authenticate ONLY if nginx set secret header (not client-forgeable)
  // This header is ONLY set by nginx AFTER auth_basic validates credentials
  const nginxAuthHeader = req.headers['x-pdev-nginx-auth'];
  if (nginxAuthHeader === 'validated') {
    // Regenerate session to avoid session fixation attacks
    req.session.regenerate((err) => {
      if (err) {
        console.error('[Auth] Session regenerate error:', err);
        return res.status(500).json({ error: 'Session initialization failed' });
      }
      req.session.authenticated = true;
      req.session.loginTime = Date.now();
      req.session.loginMethod = 'nginx-basic-auth';
      req.session.username = 'pdev'; // From nginx Basic Auth
      req.session.save((err) => {
        if (err) {
          console.error('[Auth] Auto-auth session save error:', err);
          return res.status(500).json({ error: 'Session save failed' });
        }
        console.log('[Auth] Auto-authenticated session via nginx Basic Auth');
        next();
      });
    });
  } else {
    // No nginx auth header - continue to requireSession middleware
    next();
  }
});

// Session middleware - protects browser/web UI access only
// Bypasses: X-Admin-Key, X-Pdev-Token, public paths, guest tokens
function requireSession(req, res, next) {
  // BYPASS: Requests with X-Admin-Key (admin API operations)
  if (req.headers['x-admin-key']) {
    return next();
  }

  // BYPASS: Requests with X-Pdev-Token (CLI/server automation)
  if (req.headers['x-pdev-token']) {
    return next();
  }

  // BYPASS: Public API paths
  const publicPaths = [
    '/auth/login', '/auth/logout', '/auth/check',
    '/health', '/guest/', '/contract', '/version',
    '/pdev/installer', '/webssh', 
  ];
  if (publicPaths.some(p => req.path.startsWith(p))) {
    return next();
  }

  // BYPASS: Static assets (CSS, JS, images, fonts)
  if (req.path.match(/\.(css|js|png|jpg|jpeg|gif|ico|svg|woff|woff2|ttf|eot)$/)) {
    return next();
  }

  // BYPASS: Login page
  if (req.path === '/live/login.html' || req.path === '/login.html' || req.path === '/login' || req.path === '/live/login.html') {
    return next();
  }

  // REQUIRE SESSION: Browser requests without special auth headers
  if (!req.session.authenticated) {
    // API requests get 401 JSON response
    if (req.headers.accept?.includes('application/json') ||
        req.xhr ||
        req.path.startsWith('/sessions') ||
        req.path.startsWith('/api') ||
        req.path.startsWith('/projects') ||
        req.path.startsWith('/servers')) {
      return res.status(401).json({ error: 'Authentication required' });
    }
    // HTML page requests redirect to login (use /pdev/ prefix for nginx proxy)
    return res.redirect('/pdev/live/login.html');
  }

  next();
}

app.use(requireSession);

console.log('[Auth] Session-based authentication enabled (30-day cookie)');

// ============================================================================
// STATIC FILE SERVING (Partner Self-Hosted Mode)
// ============================================================================
// For partner deployments, serve frontend HTML/CSS/JS files
// NOTE: Static serving comes AFTER session auth middleware - HTML pages require auth
// Static assets (CSS, JS, images) bypass auth via requireSession path matching
if (process.env.PDEV_SERVE_STATIC === 'true') {
  const path = require('path');
  const FRONTEND_DIR = process.env.PDEV_FRONTEND_DIR || path.join(__dirname, '..', 'frontend');

  console.log('[Static] Serving frontend files from:', FRONTEND_DIR);

  const staticOptions = {
    dotfiles: 'ignore', // Don't serve .env, .git, etc.
    index: 'index.html',
    redirect: false,
    setHeaders: (res, filePath) => {
      // Prevent caching of HTML (always get latest)
      if (filePath.endsWith('.html')) {
        res.setHeader('Cache-Control', 'no-cache, must-revalidate');
        res.setHeader('X-Content-Type-Options', 'nosniff');
        res.setHeader('X-Frame-Options', 'DENY');
      } else {
        // Cache assets for 1 year
        res.setHeader('Cache-Control', 'public, max-age=31536000, immutable');
      }
    }
  };

  // Serve static files at root (for nginx proxy with prefix stripping)
  app.use(express.static(FRONTEND_DIR, staticOptions));

  // Serve static files at /live/ (when nginx strips /pdev/ prefix)
  app.use('/live', express.static(FRONTEND_DIR, staticOptions));

  // Serve static files at /pdev/live/ (for guest links via regex location)
  app.use('/pdev/live', express.static(FRONTEND_DIR, staticOptions));
}

// Favicon route - serve from frontend directory
app.get('/favicon.ico', (req, res) => {
  res.sendFile(path.join(FRONTEND_DIR, 'favicon.svg'), {
    headers: { 'Content-Type': 'image/svg+xml' }
  });
});

// API: Expose document contract (SINGLE SOURCE OF TRUTH for frontend)
app.get('/contract', (req, res) => {
  res.json(DOC_CONTRACT);
});

// Generate short-lived share token (same-origin only, no secrets exposed)
app.post('/share-token', (req, res) => {
  // Rate limit: max 100 active tokens
  if (shareTokens.size >= MAX_SHARE_TOKENS) {
    return res.status(429).json({ error: 'Too many active share tokens' });
  }

  var crypto = require('crypto');
  var token = crypto.randomBytes(32).toString('base64url');
  var expiresAt = Date.now() + 5 * 60 * 1000; // 5 minutes

  shareTokens.set(token, { expiresAt: expiresAt, used: false });
  console.log('[SHARE] Token issued, expires: ' + new Date(expiresAt).toISOString());

  res.json({ token: token, expiresIn: 300 });
});

// Validate share token (one-time use)
function validateShareToken(token) {
  if (!token || typeof token !== 'string') return false;
  var data = shareTokens.get(token);
  if (!data) return false;
  if (Date.now() > data.expiresAt || data.used) {
    shareTokens.delete(token);
    return false;
  }
  // Mark as used (one-time)
  data.used = true;
  return true;
}

// Secure admin authentication middleware
function requireAdmin(req, res, next) {
  var authKey = req.headers['x-admin-key'];
  if (!authKey) {
    return res.status(401).json({ error: 'Missing X-Admin-Key header' });
  }
  try {
    var crypto = require('crypto');
    var keyBuffer = Buffer.from(authKey);
    var adminBuffer = Buffer.from(ADMIN_KEY);
    if (keyBuffer.length !== adminBuffer.length ||
        !crypto.timingSafeEqual(keyBuffer, adminBuffer)) {
      return res.status(401).json({ error: 'Unauthorized' });
    }
  } catch (err) {
    return res.status(401).json({ error: 'Unauthorized' });
  }
  next();
}

// Server token authentication middleware (for CLI clients)
// Validates X-Pdev-Token header against database
function requireServerToken(req, res, next) {
  var token = req.headers['x-pdev-token'];
  if (!token) {
    return res.status(401).json({ error: 'Missing X-Pdev-Token header' });
  }

  var serverInfo = serverTokensCache.get(token);
  if (!serverInfo) {
    return res.status(401).json({ error: 'Invalid server token' });
  }

  // Attach server info to request for logging/validation
  req.serverOrigin = serverInfo.server;
  next();
}

// Optional server token - allows request but attaches server info if valid
function optionalServerToken(req, res, next) {
  var token = req.headers['x-pdev-token'];
  if (token) {
    var serverInfo = serverTokensCache.get(token);
    if (serverInfo) {
      req.serverOrigin = serverInfo.server;
    }
  }
  next();
}

// Secure token validation
async function validateGuestToken(token) {
  if (!token || typeof token !== 'string' || token.length > 64) return null;

  try {
    const result = await pool.query(
      `SELECT token, token_type, session_id, server_name, project_name,
              expires_at, created_at, created_by
       FROM guest_tokens
       WHERE token = $1 AND expires_at > NOW()`,
      [token]
    );

    if (result.rows.length === 0) return null;

    const row = result.rows[0];

    // Return format matching old in-memory structure
    if (row.token_type === 'session') {
      return {
        sessionId: row.session_id,
        expiresAt: new Date(row.expires_at).getTime(),
        createdAt: new Date(row.created_at).getTime(),
        createdBy: row.created_by
      };
    } else { // project type
      return {
        type: 'project',
        server: row.server_name,
        project: row.project_name,
        expiresAt: new Date(row.expires_at).getTime(),
        createdAt: new Date(row.created_at).getTime(),
        createdBy: row.created_by
      };
    }
  } catch (err) {
    console.error('[Token] Validation error:', err);
    return null;
  }
}

// Cryptographically secure token generation
function generateToken(length) {
  length = length || 32;
  var crypto = require('crypto');
  var bytes = crypto.randomBytes(length);
  var chars = 'ABCDEFGHJKLMNPQRSTUVWXYZabcdefghijkmnopqrstuvwxyz23456789';
  var token = '';
  for (var i = 0; i < length; i++) {
    token += chars.charAt(bytes[i] % chars.length);
  }
  return token;
}

// =============================================================================
// SSE ENDPOINTS
// =============================================================================

// SSE endpoint for specific session
app.get('/events/:sessionId', async (req, res) => {
  const { sessionId } = req.params;

  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  res.setHeader('X-Accel-Buffering', 'no');

  // Get session with steps from DB
  try {
    const session = await getSessionWithSteps(sessionId);
    if (session) {
      res.write(`data: ${JSON.stringify({ type: 'init', session })}\n\n`);
    } else {
      res.write(`data: ${JSON.stringify({ type: 'error', message: 'Session not found' })}\n\n`);
    }
  } catch (err) {
    res.write(`data: ${JSON.stringify({ type: 'error', message: err.message })}\n\n`);
  }

  // Add to session-specific clients
  if (!sessionClients.has(sessionId)) {
    sessionClients.set(sessionId, new Set());
  }
  sessionClients.get(sessionId).add(res);
  console.log(`[SSE] Client connected to session ${sessionId}. Total: ${sessionClients.get(sessionId).size}`);

  req.on('close', () => {
    sessionClients.get(sessionId)?.delete(res);
    console.log(`[SSE] Client disconnected from session ${sessionId}`);
  });
});

// SSE endpoint for all sessions (dashboard)
app.get('/events', async (req, res) => {
  res.setHeader('Content-Type', 'text/event-stream');
  res.setHeader('Cache-Control', 'no-cache');
  res.setHeader('Connection', 'keep-alive');
  res.setHeader('X-Accel-Buffering', 'no');

  // Send active sessions on connect
  try {
    const sessions = await getActiveSessions();
    res.write(`data: ${JSON.stringify({ type: 'init', sessions })}\n\n`);
  } catch (err) {
    res.write(`data: ${JSON.stringify({ type: 'error', message: err.message })}\n\n`);
  }

  globalClients.add(res);
  console.log(`[SSE] Global client connected. Total: ${globalClients.size}`);

  req.on('close', () => {
    globalClients.delete(res);
    console.log(`[SSE] Global client disconnected. Total: ${globalClients.size}`);
  });
});

// =============================================================================
// BROADCAST FUNCTIONS
// =============================================================================

function broadcastToSession(sessionId, event) {
  const data = JSON.stringify(event);
  const clients = sessionClients.get(sessionId);
  if (clients) {
    clients.forEach(client => {
      client.write(`data: ${data}\n\n`);
    });
  }
}

function broadcastGlobal(event) {
  const data = JSON.stringify(event);
  globalClients.forEach(client => {
    client.write(`data: ${data}\n\n`);
  });
}

// =============================================================================
// DATABASE FUNCTIONS
// =============================================================================

async function createSession({ server, hostname, project, projectPath, cwd, commandType, commandArgs, user, gitBranch, gitCommit }) {
  const result = await pool.query(`
    INSERT INTO pdev_sessions (
      server_origin, server_hostname, project_name, project_path,
      working_directory, command_type, command_args, user_identifier,
      git_branch, git_commit_sha
    ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10)
    RETURNING id, started_at
  `, [server, hostname, project, projectPath, cwd, commandType, commandArgs, user, gitBranch, gitCommit]);

  return result.rows[0];
}

async function addStep({ sessionId, stepNumber, stepType, phaseName, phaseNumber, subPhase, contentMarkdown, commandText, exitCode, documentName, fileCreatedAt, fileModifiedAt }) {
  // SECURITY: Sanitize markdown to prevent XSS attacks
  const contentHtml = contentMarkdown ? DOMPurify.sanitize(marked.parse(contentMarkdown), {
    ALLOWED_TAGS: ['h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'p', 'ul', 'ol', 'li', 'code', 'pre', 'a', 'strong', 'em', 'blockquote', 'table', 'tr', 'td', 'th', 'thead', 'tbody', 'br', 'hr', 'span', 'div'],
    ALLOWED_ATTR: ['href', 'class', 'id']
  }) : null;
  const contentPlain = contentMarkdown ? contentMarkdown.replace(/[#*_`]/g, '').substring(0, 500) : null;

  const result = await pool.query(`
    INSERT INTO pdev_session_steps (
      session_id, step_number, step_type, phase_name, phase_number,
      sub_phase, content_markdown, content_html, content_plain,
      command_text, exit_code, output_byte_size, document_name,
      file_created_at, file_modified_at
    ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13, $14, $15)
    RETURNING id, created_at
  `, [
    sessionId, stepNumber, stepType, phaseName, phaseNumber,
    subPhase, contentMarkdown, contentHtml, contentPlain,
    commandText, exitCode, contentMarkdown?.length || 0, documentName || null,
    fileCreatedAt || null, fileModifiedAt || null
  ]);

  // DUAL-WRITE: Also save documents to project-scoped table (survives session deletion)
  try {
    if (stepType === 'document' && documentName && contentMarkdown) {
      // Get session details to populate server_origin and project_name
      const sessionResult = await pool.query(
        'SELECT server_origin, project_name FROM pdev_sessions WHERE id = $1',
        [sessionId]
      );

      if (sessionResult.rows.length > 0) {
        const { server_origin, project_name } = sessionResult.rows[0];

        // Extract version from content
        const versionMatch = contentMarkdown.match(/pdev_version:\s*([0-9.]+)/);
        const version = versionMatch ? versionMatch[1] : null;

        // Upsert into pdev_project_documents (latest version wins)
        await pool.query(`
          INSERT INTO pdev_project_documents
            (server_origin, project_name, document_name, content, content_html, version,
             file_created_at, file_modified_at, phase_number, phase_name, updated_at)
          VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, NOW())
          ON CONFLICT (server_origin, project_name, document_name)
          DO UPDATE SET
            content = EXCLUDED.content,
            content_html = EXCLUDED.content_html,
            version = EXCLUDED.version,
            file_created_at = EXCLUDED.file_created_at,
            file_modified_at = EXCLUDED.file_modified_at,
            phase_number = EXCLUDED.phase_number,
            phase_name = EXCLUDED.phase_name,
            updated_at = NOW()
        `, [
          server_origin, project_name, documentName, contentMarkdown, contentHtml, version,
          fileCreatedAt || null, fileModifiedAt || null, phaseNumber || null, phaseName || null
        ]);

        console.log(`[Document] Saved to project_documents: ${project_name}/${documentName}`);
      } else {
        console.warn(`[Document] Session ${sessionId} not found - skipping dual-write for ${documentName}`);
      }
    }
  } catch (dualWriteError) {
    // Non-fatal: Main insert already succeeded
    console.error('[Document] Dual-write failed (non-fatal):', {
      sessionId,
      documentName,
      error: dualWriteError.message
    });
  }

  return result.rows[0];
}

async function completeSession(sessionId, status = 'completed', summaryMarkdown = null) {
  // SECURITY: Sanitize markdown to prevent XSS attacks
  const summaryHtml = summaryMarkdown ? DOMPurify.sanitize(marked.parse(summaryMarkdown), {
    ALLOWED_TAGS: ['h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'p', 'ul', 'ol', 'li', 'code', 'pre', 'a', 'strong', 'em', 'blockquote', 'table', 'tr', 'td', 'th', 'thead', 'tbody', 'br', 'hr', 'span', 'div'],
    ALLOWED_ATTR: ['href', 'class', 'id']
  }) : null;

  await pool.query(`
    UPDATE pdev_sessions
    SET session_status = $2, completed_at = NOW(), summary_markdown = $3, summary_html = $4
    WHERE id = $1
  `, [sessionId, status, summaryMarkdown, summaryHtml]);
}

async function getSessionWithSteps(sessionId) {
  const sessionResult = await pool.query(`
    SELECT * FROM pdev_sessions WHERE id = $1 AND deleted_at IS NULL
  `, [sessionId]);

  if (sessionResult.rows.length === 0) return null;

  const stepsResult = await pool.query(`
    SELECT * FROM pdev_session_steps WHERE session_id = $1 ORDER BY step_number
  `, [sessionId]);

  return {
    ...sessionResult.rows[0],
    steps: stepsResult.rows
  };
}

async function getActiveSessions() {
  const result = await pool.query(`
    SELECT * FROM v_active_sessions
  `);
  return result.rows;
}

async function getSessionHistory(limit = 50, offset = 0) {
  const result = await pool.query(`
    SELECT * FROM v_session_history LIMIT $1 OFFSET $2
  `, [limit, offset]);
  return result.rows;
}

async function getSessionsByServer(server) {
  const result = await pool.query(`
    SELECT * FROM pdev_sessions
    WHERE server_origin = $1 AND deleted_at IS NULL
    ORDER BY started_at DESC LIMIT 20
  `, [server]);
  return result.rows;
}

async function getNextStepNumber(sessionId) {
  const result = await pool.query(`
    SELECT COALESCE(MAX(step_number), 0) + 1 as next FROM pdev_session_steps WHERE session_id = $1
  `, [sessionId]);
  return result.rows[0].next;
}

/**
 * Execute database operations in a transaction
 * Prevents partial updates on failure
 */
async function withTransaction(callback) {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    const result = await callback(client);
    await client.query('COMMIT');
    return result;
  } catch (err) {
    await client.query('ROLLBACK');
    throw err;
  } finally {
    client.release();
  }
}

// =============================================================================
// WEBHOOK API (for remote servers)
// =============================================================================

// Create new session
app.post('/sessions', async (req, res) => {
  try {
    const { server, hostname, project, projectPath, cwd, commandType, commandArgs, user, gitBranch, gitCommit } = req.body;

    // Validate server
    if (!VALID_SERVERS.includes(server)) {
      return res.status(400).json({ error: `Invalid server: ${server}. Must be one of: ${VALID_SERVERS.join(', ')}` });
    }

    if (!project || !commandType) {
      return res.status(400).json({ error: 'Missing required fields: project, commandType' });
    }

    // Idempotency check - prevent duplicate submissions within 5 second window
    const idempotencyKey = `${server}:${project}:${commandType}:${user || 'anonymous'}:${gitBranch || 'default'}`;
    const now = Date.now();

    const existing = recentSessionRequests.get(idempotencyKey);
    if (existing) {
      if (now - existing.timestamp < IDEMPOTENCY_WINDOW_MS) {
        if (existing.sessionId) {
          // Session already created, return it
          console.log(`[Session] Dedup: returning existing session ${existing.sessionId}`);
          return res.json({ success: true, sessionId: existing.sessionId, deduplicated: true });
        }
        // Another request is in-flight - wait briefly
        await new Promise(resolve => setTimeout(resolve, 100));
        const updated = recentSessionRequests.get(idempotencyKey);
        if (updated && updated.sessionId) {
          console.log(`[Session] Dedup (after wait): returning session ${updated.sessionId}`);
          return res.json({ success: true, sessionId: updated.sessionId, deduplicated: true });
        }
      }
    }

    // Reserve slot BEFORE creating session (prevents race condition)
    // Enforce max size to prevent memory exhaustion attacks
    if (recentSessionRequests.size >= MAX_IDEMPOTENCY_KEYS) {
      const oldestKey = recentSessionRequests.keys().next().value;
      recentSessionRequests.delete(oldestKey);
    }
    recentSessionRequests.set(idempotencyKey, { timestamp: now, sessionId: null });

    const session = await createSession({
      server,
      hostname: hostname || server,
      project,
      projectPath,
      cwd,
      commandType,
      commandArgs: commandArgs ? JSON.stringify(commandArgs) : null,
      user,
      gitBranch,
      gitCommit
    });

    // Update cache with actual session ID
    recentSessionRequests.set(idempotencyKey, { timestamp: now, sessionId: session.id });

    console.log(`[Session] Created ${session.id} from ${server} - ${commandType}`);

    // Broadcast to global dashboard
    broadcastGlobal({
      type: 'session_created',
      session: {
        id: session.id,
        server_origin: server,
        project_name: project,
        command_type: commandType,
        started_at: session.started_at
      }
    });

    res.json({ success: true, sessionId: session.id });
  } catch (err) {
    console.error('[Session] Create error:', err);
    res.status(500).json({ error: err.message });
  }
});

// Add step to session
app.post('/sessions/:sessionId/steps', async (req, res) => {
  try {
    const { sessionId } = req.params;
    const { type, phaseName, phaseNumber, subPhase, content, command, exitCode, documentName, fileCreatedAt, fileModifiedAt } = req.body;

    if (!type) {
      return res.status(400).json({ error: 'Missing required field: type' });
    }

    const stepNumber = await getNextStepNumber(sessionId);

    const step = await addStep({
      sessionId,
      stepNumber,
      stepType: type,
      phaseName,
      phaseNumber,
      subPhase,
      contentMarkdown: content,
      commandText: command,
      exitCode,
      documentName,
      fileCreatedAt,
      fileModifiedAt
    });

    console.log(`[Step] Added #${stepNumber} to ${sessionId} - ${type}`);

    // Broadcast to session viewers
    const fullStep = {
      id: step.id,
      step_number: stepNumber,
      step_type: type,
      phase_name: phaseName,
      phase_number: phaseNumber,
      document_name: documentName,
      content_markdown: content,
      content_html: content ? DOMPurify.sanitize(marked.parse(content), {
        ALLOWED_TAGS: ['h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'p', 'ul', 'ol', 'li', 'code', 'pre', 'a', 'strong', 'em', 'blockquote', 'table', 'tr', 'td', 'th', 'thead', 'tbody', 'br', 'hr', 'span', 'div'],
        ALLOWED_ATTR: ['href', 'class', 'id']
      }) : null,
      command_text: command,
      created_at: step.created_at,
      file_created_at: fileCreatedAt || null,
      file_modified_at: fileModifiedAt || null
    };

    broadcastToSession(sessionId, {
      type: 'step',
      step: fullStep
    });

    // Also update global dashboard
    broadcastGlobal({
      type: 'session_updated',
      sessionId,
      lastStep: fullStep
    });

    res.json({ success: true, stepId: step.id, stepNumber });
  } catch (err) {
    console.error('[Step] Add error:', err);
    res.status(500).json({ error: err.message });
  }
});

// Complete session
app.post('/sessions/:sessionId/complete', async (req, res) => {
  try {
    const { sessionId } = req.params;
    const { status, summary } = req.body;

    await completeSession(sessionId, status || 'completed', summary);

    console.log(`[Session] Completed ${sessionId} - ${status || 'completed'}`);

    // Broadcast completion
    broadcastToSession(sessionId, {
      type: 'session_completed',
      status: status || 'completed'
    });

    broadcastGlobal({
      type: 'session_completed',
      sessionId,
      status: status || 'completed'
    });

    res.json({ success: true });
  } catch (err) {
    console.error('[Session] Complete error:', err);
    res.status(500).json({ error: err.message });
  }
});

// =============================================================================
// READ API (for frontend)
// =============================================================================

// Get all active sessions
app.get('/sessions/active', async (req, res) => {
  try {
    const sessions = await getActiveSessions();
    res.json(sessions);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Get session history
app.get('/sessions/history', async (req, res) => {
  try {
    const limit = parseInt(req.query.limit) || 50;
    const offset = parseInt(req.query.offset) || 0;
    const sessions = await getSessionHistory(limit, offset);
    res.json(sessions);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});


// Find active session by server + project (for resume functionality)
// MUST be before /sessions/:sessionId to avoid route conflict
app.get('/sessions/find-active', async (req, res) => {
  try {
    const { server, project } = req.query;

    if (!server || !project) {
      return res.status(400).json({ error: 'Missing required params: server, project' });
    }

    const result = await pool.query(`
      SELECT id, command_type, started_at,
        (SELECT COUNT(*) FROM pdev_session_steps WHERE session_id = pdev_sessions.id) as step_count
      FROM pdev_sessions
      WHERE server_origin = $1 AND LOWER(project_name) = LOWER($2)
        AND session_status = 'active' AND deleted_at IS NULL
      ORDER BY started_at DESC LIMIT 1
    `, [server, project]);

    if (result.rows.length > 0) {
      res.json({ found: true, session: result.rows[0] });
    } else {
      res.json({ found: false });
    }
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});
// Add after line 512 (after find-active endpoint)

// Find ANY session (active OR completed) for project - simplified client
app.get('/sessions/find-session', async (req, res) => {
  try {
    const { server, project } = req.query;
    if (!server || !project) {
      return res.status(400).json({ error: 'Missing required params: server, project' });
    }
    const result = await pool.query(`
      SELECT id, command_type, session_status, started_at,
        (SELECT COUNT(*) FROM pdev_session_steps WHERE session_id = pdev_sessions.id) as step_count
      FROM pdev_sessions
      WHERE server_origin = $1 AND LOWER(project_name) = LOWER($2) AND deleted_at IS NULL
      ORDER BY started_at DESC LIMIT 1
    `, [server, project]);
    if (result.rows.length > 0) {
      res.json({ found: true, session: result.rows[0] });
    } else {
      res.json({ found: false });
    }
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Reopen a completed/interrupted session  
app.post('/sessions/:sessionId/reopen', async (req, res) => {
  try {
    const { sessionId } = req.params;
    await pool.query(`
      UPDATE pdev_sessions
      SET session_status = 'active', updated_at = NOW()
      WHERE id = $1 AND deleted_at IS NULL
    `, [sessionId]);
    broadcastGlobal({ type: 'session_reopened', sessionId });
    res.json({ success: true, sessionId });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Get single session with steps
app.get('/sessions/:sessionId', async (req, res) => {
  try {
    const session = await getSessionWithSteps(req.params.sessionId);
    if (!session) {
      return res.status(404).json({ error: 'Session not found' });
    }
    res.json(session);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Get steps for a session (convenience endpoint)
app.get("/sessions/:sessionId/steps", async (req, res) => {
  try {
    const { sessionId } = req.params;
    const result = await pool.query(`
      SELECT * FROM pdev_session_steps WHERE session_id = $1 ORDER BY step_number
    `, [sessionId]);
    res.json({ steps: result.rows, count: result.rows.length });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Get sessions by server
app.get('/servers/:server/sessions', async (req, res) => {
  try {
    const { server } = req.params;
    if (!VALID_SERVERS.includes(server)) {
      return res.status(400).json({ error: `Invalid server: ${server}` });
    }
    const sessions = await getSessionsByServer(server);
    res.json(sessions);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// =============================================================================
// PROJECT MANAGEMENT API (Button-based UI support)
// =============================================================================

// Initialize/register a new project
app.post('/projects/init', mutationLimiter, async (req, res) => {
  try {
    const { server_origin, project_name } = req.body;

    if (!server_origin || !project_name) {
      return res.status(400).json({ error: 'Missing required fields: server_origin, project_name' });
    }

    if (!VALID_SERVERS.includes(server_origin)) {
      return res.status(400).json({ error: `Invalid server_origin: ${server_origin}. Must be one of: ${VALID_SERVERS.join(', ')}` });
    }

    const sanitizedName = project_name.replace(/[^a-zA-Z0-9_-]/g, '').slice(0, 64);
    if (!sanitizedName) {
      return res.status(400).json({ error: 'Invalid project_name: must contain alphanumeric characters' });
    }

    const result = await pool.query(
      `INSERT INTO pdev_sessions (server_origin, project_name, command_type, session_status, started_at)
       VALUES ($1, $2, 'init', 'completed', NOW())
       ON CONFLICT (server_origin, project_name) WHERE command_type = 'init'
       DO UPDATE SET started_at = NOW(), updated_at = NOW()
       RETURNING id`,
      [server_origin, sanitizedName]
    );

    broadcastGlobal({ type: 'project_init', server: server_origin, project: sanitizedName });
    res.status(201).json({ success: true, project_id: result.rows[0]?.id, project_name: sanitizedName });
  } catch (err) {
    console.error('Project init error:', err);
    res.status(500).json({ error: 'Failed to initialize project' });
  }
});

// Resume a project session (find most recent active/paused session)
app.post('/sessions/resume', mutationLimiter, async (req, res) => {
  try {
    const { server_origin, project_name } = req.body;

    if (!server_origin || !project_name) {
      return res.status(400).json({ error: 'Missing required fields: server_origin, project_name' });
    }

    if (!VALID_SERVERS.includes(server_origin)) {
      return res.status(400).json({ error: `Invalid server_origin: ${server_origin}` });
    }

    const sanitizedName = project_name.replace(/[^a-zA-Z0-9_-]/g, '').slice(0, 64);
    if (!sanitizedName) {
      return res.status(400).json({ error: 'Invalid project_name' });
    }

    const result = await pool.query(
      `UPDATE pdev_sessions
       SET session_status = 'active', updated_at = NOW()
       WHERE server_origin = $1 AND LOWER(project_name) = LOWER($2)
         AND session_status IN ('active', 'paused')
         AND deleted_at IS NULL
         AND id = (
           SELECT id FROM pdev_sessions
           WHERE server_origin = $1 AND LOWER(project_name) = LOWER($2)
             AND session_status IN ('active', 'paused')
             AND deleted_at IS NULL
           ORDER BY started_at DESC
           LIMIT 1
           FOR UPDATE SKIP LOCKED
         )
       RETURNING id, command_type, session_status`,
      [server_origin, sanitizedName]
    );

    if (result.rows.length === 0) {
      return res.status(404).json({ error: 'No resumable session found for this project' });
    }

    broadcastGlobal({ type: 'session_resumed', server: server_origin, project: sanitizedName, sessionId: result.rows[0].id });
    res.json({ success: true, session: result.rows[0] });
  } catch (err) {
    console.error('Session resume error:', err);
    res.status(500).json({ error: 'Failed to resume session' });
  }
});

// =============================================================================

// =============================================================================
// DELETE / CLEANUP API (Admin protected)
// =============================================================================

// Soft delete single session
app.delete('/sessions/:sessionId', requireAdmin, async (req, res) => {
  try {
    var sessionId = req.params.sessionId;
    await pool.query('UPDATE pdev_sessions SET deleted_at = NOW() WHERE id = $1', [sessionId]);
    console.log('[Admin] Deleted session ' + sessionId);
    broadcastGlobal({ type: 'session_deleted', sessionId: sessionId });
    res.json({ success: true, message: 'Session ' + sessionId + ' deleted' });
  } catch (err) {
    console.error('[Admin] Delete error:', err);
    res.status(500).json({ error: err.message });
  }
});

// Soft delete all sessions
app.delete('/sessions', requireAdmin, async (req, res) => {
  try {
    const olderThanDays = req.query.olderThanDays ? parseInt(req.query.olderThanDays, 10) : null;
    let result;
    if (olderThanDays) {
      // Validate to prevent SQL injection - must be positive integer 1-365
      if (isNaN(olderThanDays) || olderThanDays < 1 || olderThanDays > 365) {
        return res.status(400).json({ error: 'olderThanDays must be between 1 and 365' });
      }
      result = await pool.query(
        "UPDATE pdev_sessions SET deleted_at = NOW() WHERE deleted_at IS NULL AND started_at < NOW() - ($1 || ' days')::interval RETURNING id",
        [olderThanDays]
      );
    } else {
      result = await pool.query('UPDATE pdev_sessions SET deleted_at = NOW() WHERE deleted_at IS NULL RETURNING id');
    }
    console.log('[Admin] Deleted ' + result.rowCount + ' sessions');
    broadcastGlobal({ type: 'sessions_cleared' });
    res.json({ success: true, deleted: result.rowCount });
  } catch (err) {
    console.error('[Admin] Bulk delete error:', err);
    res.status(500).json({ error: 'Failed to delete sessions' });
  }
});

// =============================================================================
// GUEST TEMP LINK API
// =============================================================================

// Create guest link for a session (Admin or Share Token)
app.post('/guest-links', async (req, res) => {
  // Accept either admin key OR share token
  var shareToken = req.headers['x-share-token'];
  var adminKey = req.headers['x-admin-key'];

  if (shareToken) {
    if (!validateShareToken(shareToken)) {
      return res.status(401).json({ error: 'Invalid or expired share token' });
    }
  } else if (adminKey) {
    var crypto = require('crypto');
    try {
      var keyBuffer = Buffer.from(adminKey);
      var adminBuffer = Buffer.from(ADMIN_KEY);
      if (keyBuffer.length !== adminBuffer.length ||
          !crypto.timingSafeEqual(keyBuffer, adminBuffer)) {
        return res.status(401).json({ error: 'Unauthorized' });
      }
    } catch (err) {
      return res.status(401).json({ error: 'Unauthorized' });
    }
  } else {
    return res.status(401).json({ error: 'Missing authentication' });
  }
  try {
    var sessionId = req.body.sessionId;
    var expiresInHours = req.body.expiresInHours || 24;
    
    if (!sessionId) {
      return res.status(400).json({ error: 'sessionId required' });
    }
    
    // Enforce MAX_GUEST_TOKENS
    const countResult = await pool.query(
      'SELECT COUNT(*) FROM guest_tokens WHERE expires_at > NOW()'
    );
    const activeTokens = parseInt(countResult.rows[0].count);

    if (activeTokens >= MAX_GUEST_TOKENS) {
      return res.status(503).json({ error: 'Token limit reached, try again later' });
    }
    
    // Verify session exists
    var session = await getSessionWithSteps(sessionId);
    if (!session) {
      return res.status(404).json({ error: 'Session not found' });
    }
    
    var token = generateToken(32);
    var expiresAt = Date.now() + (expiresInHours * 60 * 60 * 1000);

    await pool.query(
      `INSERT INTO guest_tokens (token, token_type, session_id, expires_at, created_by)
       VALUES ($1, $2, $3, $4, $5)`,
      [token, 'session', sessionId, new Date(expiresAt), req.headers['x-user'] || 'admin']
    );
    
    console.log('[Guest] Created link for session ' + sessionId + ', expires in ' + expiresInHours + 'h');

    // Construct guest URL safely using URL constructor
    const guestUrl = new URL('/session.html', PDEV_BASE_URL);
    guestUrl.searchParams.set('guest', token);

    res.json({
      success: true,
      token: token,
      url: guestUrl.toString(),
      expiresAt: new Date(expiresAt).toISOString(),
      expiresInHours: expiresInHours
    });
  } catch (err) {
    console.error('[Guest] Create link error:', err);
    res.status(500).json({ error: err.message });
  }
});

// Create share link for a project (Admin or Share Token)
app.post('/project-share', async (req, res) => {
  // Accept either admin key OR share token
  var shareToken = req.headers['x-share-token'];
  var adminKey = req.headers['x-admin-key'];

  if (shareToken) {
    if (!validateShareToken(shareToken)) {
      return res.status(401).json({ error: 'Invalid or expired share token' });
    }
  } else if (adminKey) {
    var crypto = require('crypto');
    try {
      var keyBuffer = Buffer.from(adminKey);
      var adminBuffer = Buffer.from(ADMIN_KEY);
      if (keyBuffer.length !== adminBuffer.length ||
          !crypto.timingSafeEqual(keyBuffer, adminBuffer)) {
        return res.status(401).json({ error: 'Unauthorized' });
      }
    } catch (err) {
      return res.status(401).json({ error: 'Unauthorized' });
    }
  } else {
    return res.status(401).json({ error: 'Missing authentication' });
  }
  try {
    var server = req.body.server;
    var project = req.body.project;
    var expiresInHours = req.body.expiresInHours || 72;

    if (!server || !project) {
      return res.status(400).json({ error: 'server and project required' });
    }

    // Enforce MAX_GUEST_TOKENS
    const countResult = await pool.query(
      'SELECT COUNT(*) FROM guest_tokens WHERE expires_at > NOW()'
    );
    const activeTokens = parseInt(countResult.rows[0].count);

    if (activeTokens >= MAX_GUEST_TOKENS) {
      return res.status(503).json({ error: 'Token limit reached, try again later' });
    }

    var token = generateToken(32);
    var expiresAt = Date.now() + (expiresInHours * 60 * 60 * 1000);

    await pool.query(
      `INSERT INTO guest_tokens (token, token_type, server_name, project_name, expires_at, created_by)
       VALUES ($1, $2, $3, $4, $5, $6)`,
      [token, 'project', server, project, new Date(expiresAt), req.headers['x-user'] || 'admin']
    );

    console.log('[Guest] Created project link for ' + server + '/' + project + ', expires in ' + expiresInHours + 'h');

    // Construct project share URL safely using URL constructor
    const shareUrl = new URL('/project.html', PDEV_BASE_URL);
    shareUrl.searchParams.set('project', project);
    shareUrl.searchParams.set('server', server);
    shareUrl.searchParams.set('guest', token);

    res.json({
      success: true,
      token: token,
      shareUrl: shareUrl.toString(),
      expiresAt: new Date(expiresAt).toISOString(),
      expiresInHours: expiresInHours
    });
  } catch (err) {
    console.error('[Guest] Create project link error:', err);
    res.status(500).json({ error: err.message });
  }
});

// List active guest links (Admin only)
app.get('/guest-links', requireAdmin, async (req, res) => {
  try {
    var links = [];
    var now = Date.now();
    
    guestTokens.forEach(function(data, token) {
      if (data.expiresAt > now) {
        links.push({
          token: token.substring(0, 8) + '...',
          sessionId: data.sessionId,
          expiresAt: new Date(data.expiresAt).toISOString(),
          createdBy: data.createdBy,
          remainingHours: Math.round((data.expiresAt - now) / (60 * 60 * 1000))
        });
      }
    });
    
    res.json({ links: links, count: links.length });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Revoke guest link (Admin only)
app.delete('/guest-links/:token', requireAdmin, async (req, res) => {
  try {
    var token = req.params.token;

    const result = await pool.query(
      'DELETE FROM guest_tokens WHERE token = $1 RETURNING token',
      [token]
    );

    if (result.rowCount > 0) {
      console.log('[Guest] Revoked link ' + token.substring(0, 8) + '...');
      res.json({ success: true, message: 'Link revoked' });
    } else {
      res.status(404).json({ error: 'Link not found' });
    }
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Validate guest token and get session (Public - for guests)
app.get('/guest/:token', async (req, res) => {
  try {
    var token = req.params.token;
    var guest = await validateGuestToken(token);
    
    if (!guest) {
      return res.status(401).json({ error: 'Invalid or expired guest link' });
    }
    
    var session = await getSessionWithSteps(guest.sessionId);
    if (!session) {
      return res.status(404).json({ error: 'Session not found' });
    }
    
    res.json({
      success: true,
      sessionId: guest.sessionId,
      session: session,
      expiresAt: new Date(guest.expiresAt).toISOString()
    });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});
// LEGACY API (backward compatibility with v1)
// =============================================================================

// Legacy update endpoint - creates session if needed, adds step
app.post('/update', async (req, res) => {
  try {
    const { type, command, content, project, server, documentName } = req.body;

    // Get or create a session
    let sessionId;
    const activeSessions = await pool.query(`
      SELECT id FROM pdev_sessions
      WHERE server_origin = $1 AND session_status = 'active' AND deleted_at IS NULL
      ORDER BY started_at DESC LIMIT 1
    `, [server || config.partner.serverName]);

    if (activeSessions.rows.length > 0) {
      sessionId = activeSessions.rows[0].id;
    } else {
      // Create new session
      const session = await createSession({
        server: server || config.partner.serverName,
        hostname: server || config.partner.serverName,
        project: project || 'Unknown',
        commandType: command ? command.replace('/', '') : 'unknown'
      });
      sessionId = session.id;
    }

    const stepNumber = await getNextStepNumber(sessionId);

    await addStep({
      sessionId,
      stepNumber,
      stepType: type || 'output',
      contentMarkdown: content,
      documentName,
      commandText: command
    });

    // Broadcast
    broadcastToSession(sessionId, {
      type: 'step',
      step: {
        step_number: stepNumber,
        step_type: type || 'output',
        content_markdown: content,
        content_html: content ? DOMPurify.sanitize(marked.parse(content), {
          ALLOWED_TAGS: ['h1', 'h2', 'h3', 'h4', 'h5', 'h6', 'p', 'ul', 'ol', 'li', 'code', 'pre', 'a', 'strong', 'em', 'blockquote', 'table', 'tr', 'td', 'th', 'thead', 'tbody', 'br', 'hr', 'span', 'div'],
          ALLOWED_ATTR: ['href', 'class', 'id']
        }) : null,
        command_text: command
      }
    });

    res.json({ success: true, sessionId });
  } catch (err) {
    console.error('[Legacy Update] Error:', err);
    res.status(500).json({ error: err.message });
  }
});

// Legacy session endpoint
app.get('/session', async (req, res) => {
  try {
    const sessions = await getActiveSessions();
    if (sessions.length > 0) {
      const session = await getSessionWithSteps(sessions[0].id);
      res.json(session);
    } else {
      res.json({ id: null, steps: [] });
    }
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Legacy reset endpoint - marks all active sessions as completed (Admin only)
app.post('/reset', requireAdmin, async (req, res) => {
  try {
    const result = await pool.query(
      `UPDATE pdev_sessions
       SET session_status = $1, completed_at = NOW()
       WHERE session_status = $2 AND deleted_at IS NULL
       RETURNING id`,
      ['completed', 'active']
    );

    const completed = result.rowCount || 0;
    console.log('[Reset] Completed ' + completed + ' active sessions');

    if (typeof broadcastGlobal === 'function') {
      try {
        broadcastGlobal({ type: 'reset' });
      } catch (broadcastErr) {
        console.error('[Reset] Broadcast failed:', broadcastErr.message);
      }
    }

    res.json({ success: true, completed: completed });
  } catch (err) {
    console.error('[Reset] Database error:', err.message);
    res.status(500).json({ error: 'Failed to reset sessions' });
  }
});

// =============================================================================
// VERSION & AUTO-UPDATE API
// =============================================================================

// Version info - used by remote servers to check for updates
// INCREMENT version when making changes that should propagate to satellites
const PDEV_VERSION = {
  version: '2.2.0',
  buildTime: new Date().toISOString(),
  serverFiles: ['server.js', 'doc-contract.json'],
  frontendFiles: ['project.html', 'session.html', 'index.html']
};

// Get current version (for update checks)
app.get('/version', (req, res) => {
  res.json({
    version: PDEV_VERSION.version,
    buildTime: PDEV_VERSION.buildTime,
    serverFiles: PDEV_VERSION.serverFiles,
    frontendFiles: PDEV_VERSION.frontendFiles
  });
});

// Get file content for auto-update (admin only)
app.get('/update-file/:filename', requireAdmin, (req, res) => {
  const { filename } = req.params;
  const allowedServerFiles = ['server.js', 'doc-contract.json'];
  const allowedFrontendFiles = ['project.html', 'session.html', 'index.html'];
  const allAllowed = [...allowedServerFiles, ...allowedFrontendFiles];

  // Security: sanitize filename, prevent path traversal
  const sanitizedFilename = path.basename(filename);
  if (filename !== sanitizedFilename || filename.includes('..') || !allAllowed.includes(sanitizedFilename)) {
    return res.status(400).json({ error: 'File not allowed: ' + filename });
  }

  // Determine file path based on type
  let filePath;
  if (allowedServerFiles.includes(sanitizedFilename)) {
    filePath = path.join(__dirname, sanitizedFilename);
  } else {
    filePath = path.join(FRONTEND_DIR, sanitizedFilename);
  }

  try {
    const content = fs.readFileSync(filePath, 'utf8');
    const crypto = require('crypto');
    const hash = crypto.createHash('sha256').update(content).digest('hex');

    res.json({
      filename: sanitizedFilename,
      content: content,
      hash: hash,
      size: content.length,
      version: PDEV_VERSION.version
    });
  } catch (err) {
    res.status(500).json({ error: 'Failed to read file: ' + err.message });
  }
});

// =============================================================================
// HEALTH & INFO
// =============================================================================

app.get('/health', async (req, res) => {
  try {
    // Test DB connection
    await pool.query('SELECT 1');

    const sessions = await getActiveSessions();

    res.json({
      status: 'ok',
      version: '2.0.0',
      baseUrl: PDEV_BASE_URL,
      environment: process.env.NODE_ENV || 'development',
      database: 'connected',
      activeSessions: sessions.length,
      globalClients: globalClients.size,
      sessionClients: Array.from(sessionClients.entries()).map(([id, clients]) => ({
        sessionId: id,
        clients: clients.size
      })),
      uptime: process.uptime(),
      timestamp: new Date().toISOString()
    });
  } catch (err) {
    res.status(500).json({
      status: 'error',
      database: 'disconnected',
      error: err.message
    });
  }
});

// =============================================================================
// SERVER TOKEN REGISTRATION API (for project mode installers)
// =============================================================================

// Registration secret for auto-provisioning (from env or generate warning)
const REGISTRATION_SECRET = process.env.PDEV_REGISTRATION_SECRET;
if (!REGISTRATION_SECRET) {
  console.warn('[Auth] PDEV_REGISTRATION_SECRET not set - token registration disabled');
}

// Rate limiting for registration attempts
const registrationAttempts = new Map(); // IP -> { count, resetAt }
const MAX_RATE_LIMIT_ENTRIES = 10000;

function checkRegistrationRateLimit(ip) {
  // Emergency protection against memory exhaustion
  if (registrationAttempts.size >= MAX_RATE_LIMIT_ENTRIES) {
    console.error('[Auth] Rate limit map at capacity - rejecting new IPs');
    return false;
  }

  const now = Date.now();
  const window = 15 * 60 * 1000; // 15 minutes
  const maxAttempts = 5;

  let record = registrationAttempts.get(ip);
  if (!record || now > record.resetAt) {
    record = { count: 0, resetAt: now + window };
    registrationAttempts.set(ip, record);
  }

  if (record.count >= maxAttempts) {
    return false;
  }

  record.count++;
  return true;
}

// Clean up old rate limit entries every hour
setInterval(() => {
  try {
    const now = Date.now();
    let cleaned = 0;
    for (const [ip, record] of registrationAttempts.entries()) {
      if (now > record.resetAt) {
        registrationAttempts.delete(ip);
        cleaned++;
      }
    }
    if (cleaned > 0) {
      console.log(`[Auth] Cleaned ${cleaned} expired rate limit entries`);
    }
  } catch (err) {
    console.error('[Auth] Rate limit cleanup error:', err);
  }
}, 60 * 60 * 1000);


// ============================================================================
// REGISTRATION CODE ENDPOINTS (Secure Time-Limited Provisioning)
// ============================================================================

// Utility: Extract client IP with proxy support
function getClientIP(req) {
  const forwarded = req.headers['x-forwarded-for'];
  if (forwarded) {
    return forwarded.split(',')[0].trim();
  }
  if (req.headers['x-real-ip']) {
    return req.headers['x-real-ip'];
  }
  return req.ip || req.socket.remoteAddress;
}

// Utility: Validate server name format
function validateServerName(name) {
  if (!name || typeof name !== 'string') {
    throw new Error('Server name is required');
  }
  if (name.length < 2 || name.length > 50) {
    throw new Error('Server name must be 2-50 characters');
  }
  if (!/^[a-zA-Z0-9._-]+$/.test(name)) {
    throw new Error('Server name contains invalid characters (alphanumeric, dot, underscore, dash only)');
  }
  return name;
}

// POST /admin/registration-code - Generate time-limited registration code
app.post('/admin/registration-code', async (req, res) => {
  const authHeader = req.headers.authorization;

  // HTTP Basic Auth required (nginx enforces, but double-check)
  if (!authHeader || !authHeader.startsWith('Basic ')) {
    return res.status(401).json({
      error: 'Admin authentication required',
      code: 'UNAUTHORIZED',
      message: 'This endpoint requires HTTP Basic Auth'
    });
  }

  const clientIP = getClientIP(req);
  const createdBy = req.headers['x-authenticated-user'] || 'admin';
  const client = await pool.connect();

  try {
    await client.query('BEGIN');

    // Generate cryptographically secure random code
    const code = crypto.randomBytes(16).toString('hex'); // 32 chars
    const expiresAt = new Date(Date.now() + 3600000); // 1 hour from now

    await client.query(`
      INSERT INTO registration_codes (code, expires_at, created_by, created_ip)
      VALUES ($1, $2, $3, $4)
    `, [code, expiresAt, createdBy, clientIP]);

    await client.query('COMMIT');

    console.log(`[REGCODE] Created: ${code.substring(0, 4)}... by ${createdBy} from ${clientIP}`);

    res.status(201).json({
      success: true,
      code,
      expiresAt: expiresAt.toISOString(),
      expiresIn: 3600,
      message: 'Use this code once within 1 hour for automated installation'
    });

  } catch (err) {
    await client.query('ROLLBACK');
    console.error('[REGCODE] Generation failed:', err.message);

    if (err.code === '23505') { // Unique violation (extremely rare with crypto.randomBytes)
      return res.status(500).json({
        error: 'Code generation collision (retry)',
        code: 'COLLISION'
      });
    }

    res.status(500).json({
      error: 'Failed to generate registration code',
      code: 'INTERNAL_ERROR'
    });

  } finally {
    client.release();
  }
});

// POST /tokens/register-with-code - Register server using time-limited code
app.post('/tokens/register-with-code', async (req, res) => {
  const { code, serverName, hostname } = req.body;
  const clientIP = getClientIP(req);

  // Validate registration code format (32 hex chars)
  if (!code || typeof code !== 'string') {
    return res.status(400).json({
      error: 'Registration code is required',
      code: 'MISSING_CODE'
    });
  }

  if (!/^[a-f0-9]{32}$/i.test(code)) {
    return res.status(400).json({
      error: 'Invalid registration code format (expected 32 hex characters)',
      code: 'INVALID_CODE_FORMAT'
    });
  }

  // Validate and sanitize server name
  let validatedName;
  try {
    validatedName = validateServerName(serverName);
  } catch (err) {
    return res.status(400).json({
      error: err.message,
      code: 'INVALID_SERVER_NAME'
    });
  }

  const client = await pool.connect();

  try {
    await client.query('BEGIN');

    // Atomically consume the registration code (prevents race conditions)
    const codeResult = await client.query(`
      UPDATE registration_codes
      SET consumed_at = NOW(),
          consumed_by = $1,
          consumed_ip = $2
      WHERE code = $3
        AND consumed_at IS NULL
        AND expires_at > NOW()
      RETURNING id, created_by, created_at, expires_at
    `, [validatedName, clientIP, code]);

    if (codeResult.rows.length === 0) {
      // Code not found, already used, or expired - determine which
      const codeCheck = await client.query(`
        SELECT consumed_at, expires_at
        FROM registration_codes
        WHERE code = $1
      `, [code]);

      await client.query('ROLLBACK');

      if (codeCheck.rows.length === 0) {
        return res.status(404).json({
          error: 'Registration code not found',
          code: 'CODE_NOT_FOUND',
          message: 'Invalid or non-existent registration code'
        });
      }

      const codeData = codeCheck.rows[0];
      if (codeData.consumed_at) {
        return res.status(409).json({
          error: 'Registration code already used',
          code: 'CODE_ALREADY_USED',
          message: 'This code has already been consumed'
        });
      }

      if (new Date(codeData.expires_at) <= new Date()) {
        return res.status(410).json({
          error: 'Registration code expired',
          code: 'CODE_EXPIRED',
          message: 'This code has expired - generate a new one'
        });
      }

      // Should not reach here, but handle gracefully
      return res.status(500).json({
        error: 'Code validation failed',
        code: 'VALIDATION_ERROR'
      });
    }

    // Check if server already registered
    const existingToken = await client.query(`
      SELECT token FROM server_tokens WHERE server_name = $1
    `, [validatedName]);

    if (existingToken.rows.length > 0) {
      await client.query('ROLLBACK');
      return res.status(409).json({
        error: 'Server already registered',
        code: 'SERVER_EXISTS',
        message: `Server '${validatedName}' already has a token registered`
      });
    }

    // Generate new secure token
    const token = crypto.randomBytes(32).toString('hex'); // 64 chars

    await client.query(`
      INSERT INTO server_tokens (server_name, token)
      VALUES ($1, $2)
    `, [validatedName, token]);

    await client.query('COMMIT');

    // Reload tokens into memory
    await loadServerTokens();

    console.log(`[REGCODE] Consumed: ${code.substring(0, 4)}... by ${validatedName} from ${clientIP}`);
    console.log(`[TOKEN] Registered: ${validatedName} with token ${token.substring(0, 8)}...`);

    res.status(201).json({
      success: true,
      token,
      serverName: validatedName,
      message: 'Server registered successfully - store this token securely (it cannot be retrieved again)'
    });

  } catch (err) {
    await client.query('ROLLBACK');
    console.error('[REGCODE] Registration failed:', err.message);

    if (err.code === '23505') { // Unique violation on server_name or token
      return res.status(409).json({
        error: 'Server already registered',
        code: 'SERVER_EXISTS'
      });
    }

    res.status(500).json({
      error: 'Failed to register server',
      code: 'INTERNAL_ERROR'
    });

  } finally {
    client.release();
  }
});
// Register a new server token (for project mode installers)
app.post('/tokens/register', async (req, res) => {
  // Check if registration is enabled
  if (!REGISTRATION_SECRET) {
    return res.status(503).json({
      error: 'Token registration not configured on this server',
      code: 'REGISTRATION_DISABLED'
    });
  }

  const clientIP = req.ip || req.socket.remoteAddress;

  // Rate limit check
  if (!checkRegistrationRateLimit(clientIP)) {
    console.warn(`[Auth] Registration rate limit exceeded for ${clientIP}`);
    return res.status(429).json({
      error: 'Too many registration attempts. Try again in 15 minutes.',
      code: 'RATE_LIMITED',
      retryAfter: 900
    });
  }

  // Validate registration secret
  const providedSecret = req.headers['x-registration-secret'];
  if (!providedSecret) {
    return res.status(401).json({
      error: 'Registration secret required',
      code: 'MISSING_SECRET'
    });
  }

  // Timing-safe comparison using hash (prevents length oracle attack)
  const crypto = require('crypto');
  const secretHash = crypto.createHash('sha256').update(REGISTRATION_SECRET).digest();
  const providedHash = crypto.createHash('sha256').update(providedSecret).digest();
  if (!crypto.timingSafeEqual(secretHash, providedHash)) {
    console.warn(`[Auth] Invalid registration secret from ${clientIP}`);
    return res.status(401).json({
      error: 'Invalid registration secret',
      code: 'INVALID_SECRET'
    });
  }

  // Validate request body
  const { serverName, hostname } = req.body;
  if (!serverName || typeof serverName !== 'string') {
    return res.status(400).json({
      error: 'serverName is required',
      code: 'MISSING_SERVER_NAME'
    });
  }

  // Sanitize serverName: only alphanumeric, dash, underscore
  const sanitizedName = serverName.replace(/[^a-zA-Z0-9_-]/g, '').substring(0, 50);
  if (sanitizedName.length < 2) {
    return res.status(400).json({
      error: 'serverName must be at least 2 alphanumeric characters',
      code: 'INVALID_SERVER_NAME'
    });
  }

  try {
    // Check if server already registered
    const existing = await pool.query(
      'SELECT id, revoked_at FROM server_tokens WHERE server_name = $1',
      [sanitizedName]
    );

    if (existing.rows.length > 0 && !existing.rows[0].revoked_at) {
      return res.status(409).json({
        error: 'Server name already registered',
        code: 'ALREADY_REGISTERED',
        serverName: sanitizedName
      });
    }

    // Generate secure token (256 bits)
    const token = crypto.randomBytes(32).toString('hex');

    // Insert or update (if previously revoked)
    if (existing.rows.length > 0) {
      // Re-register revoked server
      await pool.query(`
        UPDATE server_tokens
        SET token = $1, created_at = NOW(), revoked_at = NULL, last_used_at = NULL
        WHERE server_name = $2
      `, [token, sanitizedName]);
    } else {
      // New registration
      await pool.query(`
        INSERT INTO server_tokens (server_name, token)
        VALUES ($1, $2)
      `, [sanitizedName, token]);
    }

    // Refresh token cache
    await loadServerTokens();

    console.log(`[Auth] Server registered: ${sanitizedName} from ${clientIP}`);

    // Return token (only time it's sent in plaintext)
    res.status(201).json({
      success: true,
      token,
      serverName: sanitizedName,
      message: 'Store this token securely - it cannot be retrieved again'
    });

  } catch (err) {
    console.error('[Auth] Registration error:', err);
    if (err.code === '23505') {
      // UNIQUE constraint violation - race condition
      return res.status(409).json({
        error: 'Server name already registered (concurrent request)',
        code: 'ALREADY_REGISTERED',
        serverName: sanitizedName
      });
    }
    res.status(500).json({
      error: 'Registration failed',
      code: 'SERVER_ERROR'
    });
  }
});

// =============================================================================
// SETTINGS API
// =============================================================================

// Get PDev git auto-commit settings
app.get('/settings', requireAdmin, async (req, res) => {
  try {
    const fs = require('fs');
    const os = require('os');
    const configPath = path.join(os.homedir(), '.pdev-git-config');

    // Default values
    let pdevAutoGit = false;
    let pdevGitRepos = [];
    let pdevGitRemote = 'origin';

    // Read config file if exists
    if (fs.existsSync(configPath)) {
      const configContent = fs.readFileSync(configPath, 'utf8');

      // Parse environment variables from bash script
      const autoGitMatch = configContent.match(/export PDEV_AUTO_GIT=(true|false)/);
      const reposMatch = configContent.match(/export PDEV_GIT_REPOS="([^"]*)"/);
      const remoteMatch = configContent.match(/export PDEV_GIT_REMOTE=(\w+)/);

      if (autoGitMatch) pdevAutoGit = autoGitMatch[1] === 'true';
      if (reposMatch) pdevGitRepos = reposMatch[1].split(':').filter(Boolean);
      if (remoteMatch) pdevGitRemote = remoteMatch[1];
    }

    res.json({
      pdevAutoGit,
      pdevGitRepos,
      pdevGitRemote
    });
  } catch (error) {
    console.error('[Settings] Failed to read settings:', error);
    res.status(500).json({ error: 'Failed to read settings' });
  }
});

// Update PDev git auto-commit settings
app.post('/settings', requireAdmin, async (req, res) => {
  try {
    const fs = require('fs');
    const os = require('os');
    const { pdevAutoGit, pdevGitRepos, pdevGitRemote } = req.body;

    // Validate input
    if (typeof pdevAutoGit !== 'boolean') {
      return res.status(400).json({ error: 'pdevAutoGit must be boolean' });
    }

    if (!Array.isArray(pdevGitRepos)) {
      return res.status(400).json({ error: 'pdevGitRepos must be array' });
    }

    if (typeof pdevGitRemote !== 'string' || !pdevGitRemote.match(/^[a-zA-Z0-9_-]+$/)) {
      return res.status(400).json({ error: 'pdevGitRemote must be valid remote name' });
    }

    // Validate repository paths
    for (const repo of pdevGitRepos) {
      // Check absolute path
      if (!path.isAbsolute(repo)) {
        return res.status(400).json({ error: `Invalid path: ${repo} (must be absolute)` });
      }

      // Resolve path (prevents path traversal via symlinks)
      let resolvedRepo;
      try {
        resolvedRepo = fs.realpathSync(repo);
      } catch (err) {
        return res.status(400).json({ error: `Repository not found: ${repo}` });
      }

      // Check is git repository
      const gitDir = path.join(resolvedRepo, '.git');
      if (!fs.existsSync(gitDir)) {
        return res.status(400).json({ error: `Not a git repository: ${repo}` });
      }
    }

    // Write to ~/.pdev-git-config
    const configPath = path.join(os.homedir(), '.pdev-git-config');
    const configContent = `# PDev Git Auto-Commit Configuration
# Generated by PDev Live Settings UI
# Last updated: ${new Date().toISOString()}

export PDEV_AUTO_GIT=${pdevAutoGit}
export PDEV_GIT_REPOS="${pdevGitRepos.join(':')}"
export PDEV_GIT_REMOTE=${pdevGitRemote}
`;

    // Write with owner-only permissions (600)
    fs.writeFileSync(configPath, configContent, { mode: 0o600 });

    console.log('[Settings] Saved PDev git auto-commit settings:', { pdevAutoGit, repoCount: pdevGitRepos.length, pdevGitRemote });

    res.json({ success: true, message: 'Settings saved successfully' });
  } catch (error) {
    console.error('[Settings] Failed to save settings:', error);
    res.status(500).json({ error: 'Failed to save settings' });
  }
});

// =============================================================================
// PROJECT MANIFESTS API
// =============================================================================

// Get manifest for a project
app.get("/manifests/:server/:project", async (req, res) => {
  try {
    const { server, project } = req.params;
    
    // First try exact match
    let result = await pool.query(
      "SELECT * FROM project_manifests WHERE server_origin = $1 AND LOWER(project_name) = LOWER($2)",
      [server, project]
    );
    
    // Fallback to dolovdev (orchestrator) if not found and not already dolovdev
    if (result.rows.length === 0 && server !== "dolovdev" && server !== "djm" && server !== "rmlve" && server !== "djm" && server !== "rmlve") {
      result = await pool.query(
        "SELECT * FROM project_manifests WHERE server_origin = $1 AND LOWER(project_name) = LOWER($2)",
        ["dolovdev", project]
      );
      // Mark as fallback so client knows
      if (result.rows.length > 0) {
        result.rows[0].fallback_from = server;
        result.rows[0].resolved_via = "dolovdev";
      }
    }
    
    if (result.rows.length === 0) {
      return res.status(404).json({ error: "Manifest not found" });
    }
    res.json(result.rows[0]);
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});
app.put("/manifests/:server/:project", async (req, res) => {
  try {
    const { server, project } = req.params;
    const { docsPath, docs } = req.body;

    if (!VALID_SERVERS.includes(server)) {
      return res.status(400).json({ error: "Invalid server: " + server });
    }

    const result = await pool.query(`
      INSERT INTO project_manifests (server_origin, project_name, docs_path, docs)
      VALUES ($1, $2, $3, $4)
      ON CONFLICT (server_origin, project_name)
      DO UPDATE SET docs_path = COALESCE($3, project_manifests.docs_path),
                    docs = COALESCE($4, project_manifests.docs) || project_manifests.docs
      RETURNING *
    `, [server, project, docsPath, docs ? JSON.stringify(docs) : null]);

    console.log("[Manifest] Updated " + server + "/" + project);
    res.json(result.rows[0]);
  } catch (err) {
    console.error("[Manifest] Error:", err);
    res.status(500).json({ error: err.message });
  }
});

// Update single doc in manifest
app.patch("/manifests/:server/:project/doc", async (req, res) => {
  try {
    const { server, project } = req.params;
    const { docType, fileName } = req.body;

    if (!docType || !fileName) {
      return res.status(400).json({ error: "docType and fileName required" });
    }

    // Upsert: create manifest if not exists, update doc entry
    const result = await pool.query(`
      INSERT INTO project_manifests (server_origin, project_name, docs)
      VALUES ($1, $2, $3::jsonb)
      ON CONFLICT (server_origin, project_name)
      DO UPDATE SET docs = project_manifests.docs || $3::jsonb
      RETURNING *
    `, [server, project, JSON.stringify({ [docType]: fileName })]);

    console.log("[Manifest] Set " + server + "/" + project + " doc " + docType + " = " + fileName);
    res.json(result.rows[0]);
  } catch (err) {
    console.error("[Manifest] Doc update error:", err);
    res.status(500).json({ error: err.message });
  }
});

// Get all manifests (for dashboard)
app.get("/manifests", async (req, res) => {
  try {
    const { server } = req.query;
    let query = "SELECT * FROM project_manifests";
    const params = [];
    if (server) {
      params.push(server);
      query += " WHERE server_origin = $1";
    }
    query += " ORDER BY updated_at DESC";
    const result = await pool.query(query, params);
    res.json({ manifests: result.rows, count: result.rows.length });
  } catch (err) {
    res.status(500).json({ error: err.message });
  }
});

// Server info
app.get('/servers', (req, res) => {
  res.json({
    servers: VALID_SERVERS,
    commands: PDEV_COMMANDS
  });
});

// =============================================================================
// WEBSSH INSTALLER ENDPOINT
// =============================================================================

const wss = new WebSocket.Server({ noServer: true });
const INSTALL_SCRIPT_URL = 'https://vyxenai.com/pdev/install.sh';
const INSTALL_SCRIPT_SHA256 = process.env.PDEV_INSTALL_SCRIPT_SHA256 || '';

// Session storage for WebSocket authentication
const installerTokens = new Map(); // Map<token, { ip, createdAt, used }>
const wsRateLimiter = new Map(); // Map<ip, { count, resetAt }>

let activeWSConnections = 0;
const MAX_CONCURRENT_WS = 10;

// Cleanup rate limiter every 5 minutes
setInterval(() => {
  const now = Date.now();
  for (const [ip, limit] of wsRateLimiter.entries()) {
    if (now > limit.resetAt + 60000) {
      wsRateLimiter.delete(ip);
    }
  }
}, 5 * 60 * 1000);

// Shell escaping for command parameters
function escapeShellArg(arg) {
  if (typeof arg !== 'string') return '';
  return "'" + arg.replace(/'/g, "'\\''") + "'";
}

// Validate FQDN for domain input
function isValidFQDN(domain) {
  if (!domain || typeof domain !== 'string') return false;
  return validator.isFQDN(domain, { require_tld: true, allow_underscores: false });
}

// Validate source URL (must be HTTPS)
function isValidSourceURL(url) {
  if (!url || typeof url !== 'string') return false;
  if (!url.startsWith('https://')) return false;
  try {
    const parsed = new URL(url);
    return isValidFQDN(parsed.hostname);
  } catch (e) {
    return false;
  }
}

// Check WebSocket rate limit (5 connections per 60 seconds per IP)
function checkWSRateLimit(ip) {
  const now = Date.now();
  const limit = wsRateLimiter.get(ip);

  if (!limit || now > limit.resetAt) {
    wsRateLimiter.set(ip, { count: 1, resetAt: now + 60000 });
    return true;
  }

  if (limit.count >= 5) {
    return false;
  }

  limit.count++;
  return true;
}

// Generate auth token for WebSocket upgrade
function generateWSAuthToken() {
  return require('crypto').randomBytes(32).toString('hex');
}

// Validate auth message
function validateAuthMessage(data) {
  const errors = [];

  if (!data.host || typeof data.host !== 'string' || data.host.length > 253) {
    errors.push('Invalid host');
  }

  if (data.port && (typeof data.port !== 'number' || data.port < 1 || data.port > 65535)) {
    errors.push('Invalid port');
  }

  if (!data.username || typeof data.username !== 'string' || data.username.length > 32) {
    errors.push('Invalid username');
  }

  if (!['password', 'key', 'privateKey'].includes(data.authMethod)) {
    errors.push('Invalid authMethod');
  }

  if (!['source', 'project'].includes(data.mode)) {
    errors.push('Invalid mode');
  }

  if (data.mode === 'source' && (!data.domain || typeof data.domain !== 'string' || data.domain.length > 253)) {
    errors.push('Invalid domain');
  }

  if (data.mode === 'project' && (!data.sourceUrl || typeof data.sourceUrl !== 'string' || data.sourceUrl.length > 2048)) {
    errors.push('Invalid sourceUrl');
  }

  if (data.authMethod === 'password' && !data.password) {
    errors.push('Password required');
  }

  if ((data.authMethod === 'key' || data.authMethod === 'privateKey') && !data.privateKey) {
    errors.push('Private key required');
  } else if (data.authMethod === 'key' || data.authMethod === 'privateKey') {
    // Validate private key format
    const keyPattern = /^-----BEGIN (RSA|OPENSSH|EC|DSA) PRIVATE KEY-----[\s\S]+-----END (RSA|OPENSSH|EC|DSA) PRIVATE KEY-----$/;
    if (!keyPattern.test(data.privateKey.trim())) {
      errors.push('Invalid private key format');
    }
    if (data.privateKey.length > 16384) {
      errors.push('Private key exceeds maximum size (16KB)');
    }
  }

  return errors;
}

// Create WebSocket session endpoint (REST API)
app.post('/pdev/installer/token', (req, res) => {
  const clientIP = req.ip; // Get real client IP from X-Forwarded-For (trust proxy enabled)

  // Rate limit check
  if (!checkWSRateLimit(clientIP)) {
    return res.status(429).json({ error: 'Too many connection attempts. Try again in 1 minute.' });
  }

  // Generate session token
  const token = generateWSAuthToken();
  installerTokens.set(token, {
    ip: clientIP,
    createdAt: Date.now(),
    used: false
  });

  // Expire token after 15 minutes
  setTimeout(() => {
    installerTokens.delete(token);
  }, 15 * 60 * 1000);

  res.json({ token });
});

// WebSocket upgrade handler
server.on('upgrade', (request, socket, head) => {
  const url = new URL(request.url, `http://${request.headers.host}`);

  if (url.pathname === '/pdev/webssh') {
    // Enforce WSS in production
    if (process.env.NODE_ENV === 'production' && !request.headers['x-forwarded-proto']?.includes('https')) {
      socket.write('HTTP/1.1 426 Upgrade Required\r\n\r\n');
      socket.destroy();
      return;
    }

    // Extract client IP from X-Forwarded-For (nginx sets this) or fallback to socket address
    // nginx uses $proxy_add_x_forwarded_for which puts real client IP first
    const xForwardedFor = request.headers['x-forwarded-for'];
    let clientIP = xForwardedFor
      ? xForwardedFor.split(',')[0].trim()
      : request.socket.remoteAddress;
    // Normalize IPv4-mapped IPv6 to match Express req.ip (::ffff:1.2.3.4 → 1.2.3.4)
    if (clientIP && clientIP.startsWith('::ffff:')) {
      clientIP = clientIP.substring(7);
    }
    const token = url.searchParams.get('token');

    // Validate token
    const session = installerTokens.get(token);
    if (!session) {
      socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n');
      socket.destroy();
      return;
    }

    // Validate IP matches
    if (session.ip !== clientIP) {
      socket.write('HTTP/1.1 403 Forbidden\r\n\r\n');
      socket.destroy();
      installerTokens.delete(token);
      return;
    }

    // Token can only be used once
    if (session.used) {
      socket.write('HTTP/1.1 403 Forbidden\r\n\r\n');
      socket.destroy();
      return;
    }

    session.used = true;

    wss.handleUpgrade(request, socket, head, (ws) => {
      wss.emit('connection', ws, request, token);
    });
  } else {
    socket.destroy();
  }
});

// WebSocket connection handler
wss.on('connection', (ws, request, token) => {
  console.log('[WebSSH] Client connected');

  // Check max concurrent connections
  if (activeWSConnections >= MAX_CONCURRENT_WS) {
    ws.send(JSON.stringify({ type: 'error', message: 'Server capacity reached. Try again later.' }));
    ws.close(1008, 'Too many connections');
    return;
  }

  activeWSConnections++;

  let sshConn = null;
  let sshStream = null;
  let installTimeout = null;

  // Message rate limiting per connection (10 messages per second)
  const messageTimestamps = [];
  const MESSAGE_RATE_LIMIT = 10;
  const MESSAGE_RATE_WINDOW = 1000; // 1 second

  ws.on('message', async (message) => {
    // Rate limit check
    const now = Date.now();
    messageTimestamps.push(now);
    // Remove timestamps older than 1 second
    while (messageTimestamps.length > 0 && messageTimestamps[0] < now - MESSAGE_RATE_WINDOW) {
      messageTimestamps.shift();
    }
    if (messageTimestamps.length > MESSAGE_RATE_LIMIT) {
      ws.send(JSON.stringify({ type: 'error', message: 'Message rate limit exceeded' }));
      ws.close(1008, 'Rate limit');
      return;
    }

    // Message size limit (64KB)
    if (message.length > 65536) {
      ws.send(JSON.stringify({ type: 'error', message: 'Message too large' }));
      ws.close(1009, 'Message too large');
      return;
    }
    let data;
    try {
      data = JSON.parse(message);
    } catch (e) {
      ws.send(JSON.stringify({ type: 'error', message: 'Invalid message format' }));
      ws.close(1008, 'Invalid JSON');
      return;
    }

    if (data.type === 'auth') {
      // Validate all inputs
      const validationErrors = validateAuthMessage(data);
      if (validationErrors.length > 0) {
        ws.send(JSON.stringify({ type: 'error', message: validationErrors.join(', ') }));
        ws.close(1008, 'Validation failed');
        return;
      }

      const { host, port, username, authMethod, password, privateKey, mode, domain, sourceUrl } = data;

      // Validate mode-specific parameters
      if (mode === 'source' && !isValidFQDN(domain)) {
        ws.send(JSON.stringify({ type: 'error', message: 'Invalid domain format' }));
        ws.close(1008, 'Invalid domain');
        return;
      }

      if (mode === 'project' && !isValidSourceURL(sourceUrl)) {
        ws.send(JSON.stringify({ type: 'error', message: 'Invalid source URL (must be HTTPS)' }));
        ws.close(1008, 'Invalid source URL');
        return;
      }

      // Build install command with --non-interactive and --force flags
      // --non-interactive: No prompts (web wizard provides all input)
      // --force: Overwrite existing installation if detected
      let installCmd = `curl -fsSL ${INSTALL_SCRIPT_URL} | sudo bash -s -- --non-interactive --force`;
      if (mode === 'source') {
        installCmd += ` --domain ${escapeShellArg(domain)}`;
      } else {
        installCmd += ` --source-url ${escapeShellArg(sourceUrl)}`;
      }

      // Create SSH connection
      sshConn = new Client();

      sshConn.on('ready', () => {
        ws.send(JSON.stringify({ type: 'output', data: '\r\n\x1b[32m✅ SSH connected\x1b[0m\r\n' }));
        ws.send(JSON.stringify({ type: 'output', data: '\x1b[33mStarting installation...\x1b[0m\r\n\r\n' }));

        // Execute install command
        sshConn.exec(installCmd, { pty: true }, (err, stream) => {
          if (err) {
            ws.send(JSON.stringify({ type: 'error', message: `Failed to execute command: ${err.message}` }));
            sshConn.end();
            ws.close(1011, 'Exec error');
            return;
          }

          sshStream = stream;

          // Set installation timeout (2 minutes)
          installTimeout = setTimeout(() => {
            if (sshConn) {
              sshConn.end();
              ws.send(JSON.stringify({
                type: 'error',
                message: 'Installation timeout (2 minutes). Please check server logs.'
              }));
              ws.close(1011, 'Timeout');
            }
          }, 2 * 60 * 1000);

          stream.on('data', (data) => {
            ws.send(JSON.stringify({ type: 'output', data: data.toString() }));
          });

          stream.stderr.on('data', (data) => {
            ws.send(JSON.stringify({ type: 'output', data: data.toString() }));
          });

          stream.on('close', (code) => {
            if (installTimeout) clearTimeout(installTimeout);

            if (code === 0) {
              ws.send(JSON.stringify({ type: 'success', message: 'Installation completed successfully!' }));
              console.log('[WebSSH] Installation succeeded:', { mode, domain, sourceUrl });
            } else {
              ws.send(JSON.stringify({ type: 'error', message: `Installation failed with exit code ${code}` }));
              console.error('[WebSSH] Installation failed:', { code, mode, domain, sourceUrl });
            }
            sshConn.end();
          });
        });
      });

      sshConn.on('error', (err) => {
        ws.send(JSON.stringify({ type: 'error', message: `SSH connection failed: ${err.message}` }));
        ws.close(1011, 'SSH error');
        console.error('[WebSSH] SSH error:', err.message);
      });

      sshConn.on('timeout', () => {
        ws.send(JSON.stringify({ type: 'error', message: 'SSH connection timeout' }));
        sshConn.end();
        ws.close(1011, 'Timeout');
        console.error('[WebSSH] SSH timeout');
      });

      // Connect to SSH server
      const connConfig = {
        host,
        port: port || 22,
        username,
        readyTimeout: 10000
      };

      if (authMethod === 'password') {
        connConfig.password = password;
      } else {
        // Normalize key: remove leading/trailing whitespace from each line
        // Users often paste keys with extra indentation from code blocks or emails
        let normalizedKey = privateKey;
        if (privateKey) {
          normalizedKey = privateKey
            .split('\n')
            .map(line => line.trim())
            .join('\n')
            .trim();
        }
        // Debug: Log key format info (first 50 chars only, no sensitive data)
        const keyPreview = normalizedKey ? normalizedKey.substring(0, 50) : 'EMPTY';
        const keyLength = normalizedKey ? normalizedKey.length : 0;
        console.log('[WebSSH] Key debug:', { keyLength, keyPreview: keyPreview + '...', hasNewlines: normalizedKey?.includes('\n') });
        connConfig.privateKey = normalizedKey;
      }

      // CRITICAL: Wrap connect() in try-catch to handle synchronous errors
      // ssh2 throws synchronous errors for invalid key formats BEFORE 'error' event fires
      // Without this, malformed keys cause unhandled exceptions that crash the WebSocket
      // handler without sending any error message to the client
      try {
        sshConn.connect(connConfig);
      } catch (err) {
        console.error('[WebSSH] SSH connect error:', err.message);
        ws.send(JSON.stringify({ type: 'error', message: `SSH connection failed: ${err.message}` }));
        sshConn.end();  // Cleanup SSH client object
        ws.close(1011, 'SSH connect error');
        return;
      }
    }
  });

  ws.on('close', () => {
    console.log('[WebSSH] Client disconnected');
    if (installTimeout) clearTimeout(installTimeout);
    if (sshStream) sshStream.end();
    if (sshConn) sshConn.end();
    installerTokens.delete(token);
    activeWSConnections--;
  });

  ws.on('error', (err) => {
    console.error('[WebSSH] WebSocket error:', err);
    if (installTimeout) clearTimeout(installTimeout);
    if (sshStream) sshStream.end();
    if (sshConn) sshConn.end();
    activeWSConnections--;
  });
});

// =============================================================================
// SCHEMA VALIDATION
// =============================================================================

/**
 * Validate database schema before starting server
 * Prevents runtime failures from missing tables
 */
async function validateDatabaseSchema() {
  const requiredTables = [
    'pdev_sessions',
    'pdev_session_steps',
    'pdev_migrations',
    'project_manifests'
  ];

  const requiredViews = [
    'pdev_steps',           // View alias
    'v_active_sessions',
    'v_session_history'
  ];

  try {
    // Check tables exist
    for (const table of requiredTables) {
      const result = await pool.query(
        `SELECT to_regclass('public.${table}') as exists`
      );
      if (!result.rows[0].exists) {
        throw new Error(`Missing required table: ${table}`);
      }
    }

    // Check views exist
    for (const view of requiredViews) {
      const result = await pool.query(
        `SELECT to_regclass('public.${view}') as exists`
      );
      if (!result.rows[0].exists) {
        console.warn(`[Schema] Missing view: ${view} (may need migration)`);
      }
    }

    // Check migrations applied
    const migResult = await pool.query(
      `SELECT migration_name FROM pdev_migrations ORDER BY applied_at`
    );
    const appliedMigrations = migResult.rows.map(r => r.migration_name);
    console.log('[Schema] Applied migrations:', appliedMigrations.join(', '));

    console.log('[Schema] ✅ Database schema validated');
    return true;
  } catch (err) {
    console.error('[Schema] ❌ Database schema validation failed:', err.message);
    console.error('[Schema] Run migrations: psql -U pdev_app -d pdev_live -f installer/migrations/*.sql');
    return false;
  }
}

// =============================================================================
// START SERVER
// =============================================================================

// Validate schema before starting server
(async () => {
  const schemaValid = await validateDatabaseSchema();
  if (!schemaValid) {
    console.error('FATAL: Database schema validation failed. Server not started.');
    process.exit(1);
  }

  // Load server tokens from database
  await loadServerTokens();

  server.listen(PORT, () => {
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    console.log('🚀 PDev Live Mirror Server v2');
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
    console.log('Environment:', process.env.NODE_ENV || 'development');
    console.log('Port:', PORT);
    console.log('Base URL:', PDEV_BASE_URL);
    console.log('CORS Origins:', ALLOWED_ORIGINS.length, 'configured');
    console.log('Database: pdev_live @', process.env.PDEV_DB_HOST || 'localhost');
    console.log('Valid servers:', VALID_SERVERS.join(', '));
    console.log('WebSSH: /pdev/webssh (installer endpoint)');
    console.log('━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━');
  });
})();

// =============================================================================
// PROJECT-CENTRIC ENDPOINTS
// =============================================================================

// Input validation helper
function validateProjectParams(server, project) {
  if (!server || typeof server !== 'string' || server.length > 50) {
    return { valid: false, error: 'Invalid server parameter' };
  }
  const projectPattern = /^[a-zA-Z0-9_\-\.]{1,100}$/;
  if (!project || !projectPattern.test(project)) {
    return { valid: false, error: 'Invalid project name format' };
  }
  return { valid: true };
}

// SQL LIKE escape helper
function escapeLikePattern(str) {
  if (typeof str !== 'string') return '';
  return str.replace(/[%_\\]/g, '\\$&');
}

// Get all projects (grouped by project name)
app.get('/projects', async (req, res) => {
  try {
    const { server } = req.query;
    const params = [];
    let serverFilter = '';
    
    if (server) {
      if (typeof server !== 'string' || server.length > 50) {
        return res.status(400).json({ error: 'Invalid server parameter' });
      }
      params.push(server);
      serverFilter = 'AND ps.server_origin = $1';
    }
    
    const query = `
      SELECT 
        ps.project_name,
        ps.server_origin,
        COUNT(DISTINCT ps.id) as session_count,
        MAX(ps.started_at) as last_activity,
        COALESCE(step_counts.total_steps, 0) as total_steps
      FROM pdev_sessions ps
      LEFT JOIN (
        SELECT s.project_name, s.server_origin, COUNT(st.id) as total_steps
        FROM pdev_sessions s
        JOIN pdev_steps st ON st.session_id = s.id
        WHERE s.deleted_at IS NULL
        GROUP BY s.project_name, s.server_origin
      ) step_counts ON step_counts.project_name = ps.project_name 
        AND step_counts.server_origin = ps.server_origin
      WHERE ps.deleted_at IS NULL ${serverFilter}
      GROUP BY ps.project_name, ps.server_origin, step_counts.total_steps
      ORDER BY last_activity DESC
    `;
    
    const result = await pool.query(query, params);
    res.json({ projects: result.rows, count: result.rows.length });
  } catch (err) {
    console.error('[Projects] Error:', err.message);
    res.status(500).json({ error: 'Failed to fetch projects' });
  }
});

// Get project documents (latest from sessions)
app.get('/projects/:server/:project/docs', async (req, res) => {
  try {
    const { server, project } = req.params;
    const validation = validateProjectParams(server, project);
    if (!validation.valid) {
      return res.status(400).json({ error: validation.error });
    }

    // Prevent browser caching of API response
    res.setHeader('Cache-Control', 'no-store, no-cache, must-revalidate, proxy-revalidate');
    res.setHeader('Pragma', 'no-cache');
    res.setHeader('Expires', '0');

    // Query project-scoped documents (survives session deletion)
    const result = await pool.query(`
      SELECT
        id as step_id,
        UPPER(REGEXP_REPLACE(TRIM(BOTH E'\\n\\r\\t ' FROM document_name), '\\.md$', '', 'i')) as document_name,
        document_name as original_name,
        content,
        updated_at as modified,
        file_created_at,
        file_modified_at,
        phase_number,
        phase_name
      FROM pdev_project_documents
      WHERE server_origin = $1 AND LOWER(project_name) = LOWER($2)
      ORDER BY phase_number NULLS LAST, document_name
    `, [server, project]);
    
    const docs = {};
    let lastModified = null;

    result.rows.forEach(row => {
      const rawDocType = row.document_name.replace(/[\r\n]/g, '').trim().replace(/\.md$/i, '').toUpperCase();
      const docType = normalizeDocType(rawDocType); // Normalize to canonical form
      let version = null;

      if (row.content) {
        const versionMatch = row.content.match(/pdev_version:\s*([0-9.]+)/);
        if (versionMatch) version = versionMatch[1];
      }

      // Use database created_at timestamp (when doc was pushed) - includes time
      const docModified = row.modified; // This is created_at from SQL

      // Only store if not already present (prefer first/latest occurrence)
      if (!docs[docType]) {
        docs[docType] = {
          id: row.step_id,
          name: row.document_name.replace(/[\r\n]/g, '').trim(),
          version: version,
          modified: docModified,
          fileCreatedAt: row.file_created_at,
          fileModifiedAt: row.file_modified_at,
          phase: row.phase_number,
          phaseName: row.phase_name ? row.phase_name.replace(/[\r\n]/g, '').trim() : null,
          hasContent: !!row.content
        };
      }

      if (!lastModified || new Date(docModified) > new Date(lastModified)) {
        lastModified = docModified;
      }
    });
    
    res.json({ ...docs, lastModified });
  } catch (err) {
    console.error('[Projects] Docs error:', err.message);
    res.status(500).json({ error: 'Failed to fetch project documents' });
  }
});

// Get specific document content
app.get('/projects/:server/:project/docs/:docType', async (req, res) => {
  try {
    const { server, project, docType } = req.params;
    const validation = validateProjectParams(server, project);
    if (!validation.valid) {
      return res.status(400).json({ error: validation.error });
    }

    if (!docType || typeof docType !== 'string' || docType.length > 50) {
      return res.status(400).json({ error: 'Invalid document type' });
    }

    // Prevent browser caching of API response
    res.setHeader('Cache-Control', 'no-store, no-cache, must-revalidate, proxy-revalidate');
    res.setHeader('Pragma', 'no-cache');
    res.setHeader('Expires', '0');

    const safeDocType = escapeLikePattern(docType.toUpperCase());

    // Query both explicit documents AND output steps with PDev doc headers
    // Normalize document_name: UPPER, TRIM whitespace/newlines, remove .md suffix
    const result = await pool.query(`
      WITH doc_steps AS (
        -- Explicit document steps
        SELECT
          id as step_id,
          UPPER(REGEXP_REPLACE(TRIM(BOTH E'\\n\\r\\t ' FROM document_name), '\\.md$', '', 'i')) as normalized_name,
          document_name as original_name,
          content_markdown as content,
          created_at as modified,
          file_created_at,
          file_modified_at,
          phase_number,
          phase_name
        FROM pdev_session_steps
        WHERE session_id IN (
          SELECT id FROM pdev_sessions
          WHERE server_origin = $1 AND LOWER(project_name) = LOWER($2) AND deleted_at IS NULL
        )
        AND step_type = 'document'
        AND document_name IS NOT NULL

        UNION ALL

        -- Output steps with matching PDev document header
        SELECT
          id as step_id,
          UPPER(TRIM(SUBSTRING(content_markdown FROM 'document:\\s*([A-Z_]+)'))) as normalized_name,
          UPPER(TRIM(SUBSTRING(content_markdown FROM 'document:\\s*([A-Z_]+)'))) as original_name,
          content_markdown as content,
          created_at as modified,
          file_created_at,
          file_modified_at,
          phase_number,
          phase_name
        FROM pdev_session_steps
        WHERE session_id IN (
          SELECT id FROM pdev_sessions
          WHERE server_origin = $1 AND LOWER(project_name) = LOWER($2) AND deleted_at IS NULL
        )
        AND step_type = 'output'
        AND content_markdown ~ '^---\\s*\\npdev_version:'
        AND content_markdown ~ 'document:\\s*[A-Z_]+'
      )
      SELECT step_id, normalized_name as document_name, original_name, content, modified, file_created_at, file_modified_at, phase_number, phase_name
      FROM doc_steps
      WHERE normalized_name IS NOT NULL AND normalized_name LIKE $3
      ORDER BY modified DESC
      LIMIT 1
    `, [server, project, '%' + safeDocType + '%']);

    if (result.rows.length === 0) {
      return res.status(404).json({ error: 'Document not found' });
    }
    
    const row = result.rows[0];
    let version = null;

    if (row.content) {
      const versionMatch = row.content.match(/pdev_version:\s*([0-9.]+)/);
      if (versionMatch) version = versionMatch[1];
    }

    // Use database created_at timestamp (when doc was pushed) - includes time
    res.json({
      id: row.step_id,
      name: row.document_name.replace(/[\r\n]/g, '').trim(),
      content: row.content,
      version: version,
      modified: row.modified,
      fileCreatedAt: row.file_created_at,
      fileModifiedAt: row.file_modified_at,
      phase: row.phase_number,
      phaseName: row.phase_name ? row.phase_name.replace(/[\r\n]/g, '').trim() : null
    });
  } catch (err) {
    console.error('[Projects] Doc content error:', err.message);
    res.status(500).json({ error: 'Failed to fetch document' });
  }
});

// Get project sessions
app.get('/projects/:server/:project/sessions', async (req, res) => {
  try {
    const { server, project } = req.params;
    const validation = validateProjectParams(server, project);
    if (!validation.valid) {
      return res.status(400).json({ error: validation.error });
    }
    
    const result = await pool.query(`
      SELECT
        ps.id,
        ps.command_type,
        ps.session_status as status,
        ps.started_at as created_at,
        ps.completed_at as ended_at,
        COUNT(st.id) as step_count
      FROM pdev_sessions ps
      LEFT JOIN pdev_steps st ON st.session_id = ps.id
      WHERE ps.server_origin = $1 AND LOWER(ps.project_name) = LOWER($2) AND ps.deleted_at IS NULL
      GROUP BY ps.id, ps.command_type, ps.session_status, ps.started_at, ps.completed_at
      ORDER BY ps.started_at DESC
      LIMIT 20
    `, [server, project]);
    
    res.json({ sessions: result.rows, count: result.rows.length });
  } catch (err) {
    console.error('[Projects] Sessions error:', err.message);
    res.status(500).json({ error: 'Failed to fetch sessions' });
  }
});
