/**
 * PDev Live Mirror Server v2
 * Multi-server session tracking with PostgreSQL persistence
 *
 * Architecture:
 * - Webhook API receives updates from all servers (dolovdev, acme, ittz, dolov, wdress)
 * - PostgreSQL stores sessions and steps with UUID-based routing
 * - SSE broadcasts to connected browsers (session-specific channels)
 * - Markdown rendered server-side for consistent display
 */

const express = require('express');
const cors = require('cors');
const path = require('path');
const { marked } = require('marked');
const hljs = require('highlight.js');
const { Pool } = require('pg');

const app = express();
const PORT = process.env.PORT || 3077;

// PostgreSQL connection pool
const pool = new Pool({
  host: 'localhost',
  port: 5432,
  database: 'pdev_live',
  user: 'pdev_app',
  password: 'PdevLive2024',
  max: 20,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 2000,
});

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

// Valid server origins
const VALID_SERVERS = ['dolovdev', 'acme', 'ittz', 'dolov', 'wdress', 'cfree', 'rmlve', 'djm'];

// Admin key for protected operations (REQUIRED)
const ADMIN_KEY = process.env.PDEV_ADMIN_KEY;
if (!ADMIN_KEY || ADMIN_KEY.length < 32) {
  console.error('FATAL: PDEV_ADMIN_KEY must be set (min 32 chars)');
  console.error('Generate with: openssl rand -base64 32');
  process.exit(1);
}

// Guest link tokens (in-memory with cleanup)
const guestTokens = new Map(); // token -> { sessionId, expiresAt, createdAt, createdBy }
const MAX_GUEST_TOKENS = 1000;

// Cleanup expired tokens every minute
const cleanupInterval = setInterval(() => {
  const now = Date.now();
  for (const [token, data] of guestTokens.entries()) {
    if (now > data.expiresAt) {
      guestTokens.delete(token);
      console.log('[TOKEN] Expired: ' + token.substring(0, 8) + '...');
    }
  }
}, 60000);

// Graceful shutdown
process.on('SIGTERM', () => {
  clearInterval(cleanupInterval);
  process.exit(0);
});

app.use(cors());
app.use(express.json({ limit: '10mb' }));

// API: Expose document contract (SINGLE SOURCE OF TRUTH for frontend)
app.get('/contract', (req, res) => {
  res.json(DOC_CONTRACT);
});

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

// Secure token validation
function validateGuestToken(token) {
  if (!token || typeof token !== 'string' || token.length > 64) return null;
  var guest = guestTokens.get(token);
  if (!guest) return null;
  if (Date.now() > guest.expiresAt) {
    guestTokens.delete(token);
    return null;
  }
  return guest;
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

async function addStep({ sessionId, stepNumber, stepType, phaseName, phaseNumber, subPhase, contentMarkdown, commandText, exitCode, documentName }) {
  const contentHtml = contentMarkdown ? marked.parse(contentMarkdown) : null;
  const contentPlain = contentMarkdown ? contentMarkdown.replace(/[#*_`]/g, '').substring(0, 500) : null;

  const result = await pool.query(`
    INSERT INTO pdev_steps (
      session_id, step_number, step_type, phase_name, phase_number,
      sub_phase, content_markdown, content_html, content_plain,
      command_text, exit_code, output_byte_size, document_name
    ) VALUES ($1, $2, $3, $4, $5, $6, $7, $8, $9, $10, $11, $12, $13)
    RETURNING id, created_at
  `, [
    sessionId, stepNumber, stepType, phaseName, phaseNumber,
    subPhase, contentMarkdown, contentHtml, contentPlain,
    commandText, exitCode, contentMarkdown?.length || 0, documentName || null
  ]);

  return result.rows[0];
}

async function completeSession(sessionId, status = 'completed', summaryMarkdown = null) {
  const summaryHtml = summaryMarkdown ? marked.parse(summaryMarkdown) : null;

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
    SELECT * FROM pdev_steps WHERE session_id = $1 ORDER BY step_number
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
    SELECT COALESCE(MAX(step_number), 0) + 1 as next FROM pdev_steps WHERE session_id = $1
  `, [sessionId]);
  return result.rows[0].next;
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
    const { type, phaseName, phaseNumber, subPhase, content, command, exitCode, documentName } = req.body;

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
      documentName
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
      content_html: content ? marked.parse(content) : null,
      command_text: command,
      created_at: step.created_at
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
        (SELECT COUNT(*) FROM pdev_steps WHERE session_id = pdev_sessions.id) as step_count
      FROM pdev_sessions
      WHERE server_origin = $1 AND project_name = $2
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
        (SELECT COUNT(*) FROM pdev_steps WHERE session_id = pdev_sessions.id) as step_count
      FROM pdev_sessions
      WHERE server_origin = $1 AND project_name = $2 AND deleted_at IS NULL
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
      SET session_status = 'active', last_activity_at = NOW()
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
      SELECT * FROM pdev_steps WHERE session_id = $1 ORDER BY step_number
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
    var olderThanDays = req.query.olderThanDays ? parseInt(req.query.olderThanDays) : null;
    var result;
    if (olderThanDays) {
      result = await pool.query(
        "UPDATE pdev_sessions SET deleted_at = NOW() WHERE deleted_at IS NULL AND started_at < NOW() - INTERVAL '" + olderThanDays + " days' RETURNING id"
      );
    } else {
      result = await pool.query('UPDATE pdev_sessions SET deleted_at = NOW() WHERE deleted_at IS NULL RETURNING id');
    }
    console.log('[Admin] Deleted ' + result.rowCount + ' sessions');
    broadcastGlobal({ type: 'sessions_cleared' });
    res.json({ success: true, deleted: result.rowCount });
  } catch (err) {
    console.error('[Admin] Bulk delete error:', err);
    res.status(500).json({ error: err.message });
  }
});

// =============================================================================
// GUEST TEMP LINK API
// =============================================================================

// Create guest link for a session (Admin only)
app.post('/guest-links', requireAdmin, async (req, res) => {
  try {
    var sessionId = req.body.sessionId;
    var expiresInHours = req.body.expiresInHours || 24;
    
    if (!sessionId) {
      return res.status(400).json({ error: 'sessionId required' });
    }
    
    // Enforce MAX_GUEST_TOKENS
    if (guestTokens.size >= MAX_GUEST_TOKENS) {
      return res.status(503).json({ error: 'Token limit reached, try again later' });
    }
    
    // Verify session exists
    var session = await getSessionWithSteps(sessionId);
    if (!session) {
      return res.status(404).json({ error: 'Session not found' });
    }
    
    var token = generateToken(32);
    var expiresAt = Date.now() + (expiresInHours * 60 * 60 * 1000);
    
    guestTokens.set(token, {
      sessionId: sessionId,
      expiresAt: expiresAt,
      createdAt: Date.now(),
      createdBy: req.headers['x-user'] || 'admin'
    });
    
    console.log('[Guest] Created link for session ' + sessionId + ', expires in ' + expiresInHours + 'h');
    
    res.json({
      success: true,
      token: token,
      url: 'https://walletsnack.com/pdev/live/session.html?guest=' + token,
      expiresAt: new Date(expiresAt).toISOString(),
      expiresInHours: expiresInHours
    });
  } catch (err) {
    console.error('[Guest] Create link error:', err);
    res.status(500).json({ error: err.message });
  }
});

// Create share link for a project (Admin only)
app.post('/project-share', requireAdmin, async (req, res) => {
  try {
    var server = req.body.server;
    var project = req.body.project;
    var expiresInHours = req.body.expiresInHours || 72;

    if (!server || !project) {
      return res.status(400).json({ error: 'server and project required' });
    }

    // Enforce MAX_GUEST_TOKENS
    if (guestTokens.size >= MAX_GUEST_TOKENS) {
      return res.status(503).json({ error: 'Token limit reached, try again later' });
    }

    var token = generateToken(32);
    var expiresAt = Date.now() + (expiresInHours * 60 * 60 * 1000);

    guestTokens.set(token, {
      type: 'project',
      server: server,
      project: project,
      expiresAt: expiresAt,
      createdAt: Date.now(),
      createdBy: req.headers['x-user'] || 'admin'
    });

    console.log('[Guest] Created project link for ' + server + '/' + project + ', expires in ' + expiresInHours + 'h');

    res.json({
      success: true,
      token: token,
      shareUrl: 'https://walletsnack.com/pdev/live/project.html?project=' + encodeURIComponent(project) + '&server=' + encodeURIComponent(server) + '&guest=' + token,
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
    
    if (guestTokens.has(token)) {
      guestTokens.delete(token);
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
    var guest = validateGuestToken(token);
    
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
    const { type, command, content, project, server } = req.body;

    // Get or create a session
    let sessionId;
    const activeSessions = await pool.query(`
      SELECT id FROM pdev_sessions
      WHERE server_origin = $1 AND session_status = 'active' AND deleted_at IS NULL
      ORDER BY started_at DESC LIMIT 1
    `, [server || 'acme']);

    if (activeSessions.rows.length > 0) {
      sessionId = activeSessions.rows[0].id;
    } else {
      // Create new session
      const session = await createSession({
        server: server || 'acme',
        hostname: server || 'acme',
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
        content_html: content ? marked.parse(content) : null,
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
      database: 'connected',
      activeSessions: sessions.length,
      globalClients: globalClients.size,
      sessionClients: Array.from(sessionClients.entries()).map(([id, clients]) => ({
        sessionId: id,
        clients: clients.size
      })),
      uptime: process.uptime()
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
// PROJECT MANIFESTS API
// =============================================================================

// Get manifest for a project
app.get("/manifests/:server/:project", async (req, res) => {
  try {
    const { server, project } = req.params;
    
    // First try exact match
    let result = await pool.query(
      "SELECT * FROM project_manifests WHERE server_origin = $1 AND project_name = $2",
      [server, project]
    );
    
    // Fallback to dolovdev (orchestrator) if not found and not already dolovdev
    if (result.rows.length === 0 && server !== "dolovdev" && server !== "djm" && server !== "rmlve" && server !== "djm" && server !== "rmlve") {
      result = await pool.query(
        "SELECT * FROM project_manifests WHERE server_origin = $1 AND project_name = $2",
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
// START SERVER
// =============================================================================

app.listen(PORT, () => {
  console.log(`[PDev Live v2] Server running on port ${PORT}`);
  console.log(`[PDev Live v2] PostgreSQL connected to pdev_live`);
  console.log(`[PDev Live v2] Valid servers: ${VALID_SERVERS.join(', ')}`);
});

// Find active session by server + project (for resume functionality)
app.get('/sessions/find-active', async (req, res) => {
  try {
    const { server, project } = req.query;
    
    if (!server || !project) {
      return res.status(400).json({ error: 'Missing required params: server, project' });
    }

    const result = await pool.query(`
      SELECT id, command_type, started_at,
        (SELECT COUNT(*) FROM pdev_steps WHERE session_id = pdev_sessions.id) as step_count
      FROM pdev_sessions
      WHERE server_origin = \$1 AND project_name = \$2 
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
    
    // Query both explicit documents AND output steps with PDev doc headers
    const result = await pool.query(`
      WITH doc_steps AS (
        -- Explicit document steps
        SELECT
          document_name,
          content_markdown as content,
          created_at as modified,
          phase_number,
          phase_name
        FROM pdev_steps
        WHERE session_id IN (
          SELECT id FROM pdev_sessions
          WHERE server_origin = $1 AND project_name = $2 AND deleted_at IS NULL
        )
        AND step_type = 'document'
        AND document_name IS NOT NULL

        UNION ALL

        -- Output steps with PDev document headers (document: IDEATION, etc)
        SELECT
          UPPER(TRIM(SUBSTRING(content_markdown FROM 'document:\\s*([A-Z_]+)'))) as document_name,
          content_markdown as content,
          created_at as modified,
          phase_number,
          phase_name
        FROM pdev_steps
        WHERE session_id IN (
          SELECT id FROM pdev_sessions
          WHERE server_origin = $1 AND project_name = $2 AND deleted_at IS NULL
        )
        AND step_type = 'output'
        AND content_markdown ~ '^---\\s*\\npdev_version:'
        AND content_markdown ~ 'document:\\s*[A-Z_]+'
      )
      SELECT DISTINCT ON (document_name)
        document_name,
        content,
        modified,
        phase_number,
        phase_name
      FROM doc_steps
      WHERE document_name IS NOT NULL
      ORDER BY document_name, modified DESC
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

      // Only store if not already present (prefer first/latest occurrence)
      if (!docs[docType]) {
        docs[docType] = {
          name: row.document_name.replace(/[\r\n]/g, '').trim(),
          version: version,
          modified: row.modified,
          phase: row.phase_number,
          phaseName: row.phase_name ? row.phase_name.replace(/[\r\n]/g, '').trim() : null,
          hasContent: !!row.content
        };
      }

      if (!lastModified || new Date(row.modified) > new Date(lastModified)) {
        lastModified = row.modified;
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
    
    const safeDocType = escapeLikePattern(docType.toUpperCase());

    // Query both explicit documents AND output steps with PDev doc headers
    const result = await pool.query(`
      WITH doc_steps AS (
        -- Explicit document steps
        SELECT
          document_name,
          content_markdown as content,
          created_at as modified,
          phase_number,
          phase_name
        FROM pdev_steps
        WHERE session_id IN (
          SELECT id FROM pdev_sessions
          WHERE server_origin = $1 AND project_name = $2 AND deleted_at IS NULL
        )
        AND step_type = 'document'
        AND UPPER(document_name) LIKE $3

        UNION ALL

        -- Output steps with matching PDev document header
        SELECT
          UPPER(TRIM(SUBSTRING(content_markdown FROM 'document:\\s*([A-Z_]+)'))) as document_name,
          content_markdown as content,
          created_at as modified,
          phase_number,
          phase_name
        FROM pdev_steps
        WHERE session_id IN (
          SELECT id FROM pdev_sessions
          WHERE server_origin = $1 AND project_name = $2 AND deleted_at IS NULL
        )
        AND step_type = 'output'
        AND content_markdown ~ '^---\\s*\\npdev_version:'
        AND UPPER(TRIM(SUBSTRING(content_markdown FROM 'document:\\s*([A-Z_]+)'))) LIKE $3
      )
      SELECT * FROM doc_steps
      WHERE document_name IS NOT NULL
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
    
    res.json({
      name: row.document_name.replace(/[\r\n]/g, '').trim(),
      content: row.content,
      version: version,
      modified: row.modified,
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
      WHERE ps.server_origin = $1 AND ps.project_name = $2 AND ps.deleted_at IS NULL
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
