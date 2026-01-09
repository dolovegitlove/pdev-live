/**
 * PDev API - Product Development Suite Database Operations
 * Port: 3022
 */

const express = require('express');
const helmet = require('helmet');
const rateLimit = require('express-rate-limit');
const { Pool } = require('pg');
const config = require('../config');

const app = express();

// Security middleware
app.use(helmet());
app.use(express.json({ limit: '100kb' }));

// Rate limiting
const apiLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: 100,
  message: { error: 'Rate limit exceeded' },
  standardHeaders: true,
  legacyHeaders: false,
});

const mutationLimiter = rateLimit({
  windowMs: 60 * 1000,
  max: 20,
  message: { error: 'Mutation rate limit exceeded' },
});

// IP allowlist (from config)
const ALLOWED_IPS = [
  '::ffff:127.0.0.1', // IPv4-mapped localhost
  ...config.servers.allowedIps,
];

app.use((req, res, next) => {
  const ip = (req.ip || req.connection.remoteAddress || '').replace(/^::ffff:/, '');
  if (!ALLOWED_IPS.includes(ip) && !ALLOWED_IPS.includes(req.ip)) {
    console.warn(`Blocked request from: ${req.ip}`);
    return res.status(403).json({ error: 'Access denied' });
  }
  next();
});

// Database pool
const pool = new Pool({
  host: 'localhost',
  database: 'pdev',
  user: 'pdev_app',
  password: process.env.PDEV_DB_PASSWORD || (() => { console.error('FATAL: PDEV_DB_PASSWORD required'); process.exit(1); })(),
  max: 3,
  idleTimeoutMillis: 30000,
  connectionTimeoutMillis: 10000,
});

const API_PREFIX = '/api/v1/pdev';

// Health check
app.get(`${API_PREFIX}/health`, (req, res) => {
  res.json({ status: 'ok', version: 'v1', timestamp: new Date().toISOString() });
});

// ============ PROJECTS ============

app.get(`${API_PREFIX}/projects`, apiLimiter, async (req, res) => {
  try {
    const { server, archived } = req.query;
    let query = 'SELECT * FROM pdev_projects WHERE 1=1';
    const params = [];
    if (server) { params.push(server); query += ` AND server = $${params.length}`; }
    if (archived !== undefined) { params.push(archived === 'true'); query += ` AND is_archived = $${params.length}`; }
    query += ' ORDER BY updated_at DESC';
    const result = await pool.query(query, params);
    res.json({ projects: result.rows, total: result.rows.length });
  } catch (error) {
    console.error('GET projects error:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

app.get(`${API_PREFIX}/projects/:id`, apiLimiter, async (req, res) => {
  try {
    const result = await pool.query('SELECT * FROM pdev_projects WHERE id = $1', [req.params.id]);
    if (result.rows.length === 0) return res.status(404).json({ error: 'Project not found' });
    res.json(result.rows[0]);
  } catch (error) {
    console.error('GET project error:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

app.post(`${API_PREFIX}/projects`, mutationLimiter, async (req, res) => {
  try {
    const { name, path, server, industry, description } = req.body;
    if (!name || typeof name !== 'string') return res.status(400).json({ error: 'name required (string)' });
    const result = await pool.query(
      'INSERT INTO pdev_projects (name, path, server, industry, description) VALUES ($1, $2, $3, $4, $5) RETURNING *',
      [name, path || null, server || null, industry || null, description || null]
    );
    res.status(201).json(result.rows[0]);
  } catch (error) {
    console.error('POST project error:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

app.put(`${API_PREFIX}/projects/:id`, mutationLimiter, async (req, res) => {
  try {
    const { name, path, server, industry, description, is_archived } = req.body;
    const result = await pool.query(
      `UPDATE pdev_projects SET 
        name = COALESCE($1, name), path = COALESCE($2, path), server = COALESCE($3, server),
        industry = COALESCE($4, industry), description = COALESCE($5, description),
        is_archived = COALESCE($6, is_archived)
      WHERE id = $7 RETURNING *`,
      [name, path, server, industry, description, is_archived, req.params.id]
    );
    if (result.rows.length === 0) return res.status(404).json({ error: 'Project not found' });
    res.json(result.rows[0]);
  } catch (error) {
    console.error('PUT project error:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

app.delete(`${API_PREFIX}/projects/:id`, mutationLimiter, async (req, res) => {
  try {
    const result = await pool.query('DELETE FROM pdev_projects WHERE id = $1 RETURNING id', [req.params.id]);
    if (result.rows.length === 0) return res.status(404).json({ error: 'Project not found' });
    res.json({ deleted: true, id: result.rows[0].id });
  } catch (error) {
    console.error('DELETE project error:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// ============ DOCUMENTS ============

app.get(`${API_PREFIX}/documents`, apiLimiter, async (req, res) => {
  try {
    const { project_id, doc_type, status } = req.query;
    let query = 'SELECT * FROM pdev_documents WHERE 1=1';
    const params = [];
    if (project_id) { params.push(project_id); query += ` AND project_id = $${params.length}`; }
    if (doc_type) { params.push(doc_type); query += ` AND doc_type = $${params.length}`; }
    if (status) { params.push(status); query += ` AND status = $${params.length}`; }
    query += ' ORDER BY modified_at DESC';
    const result = await pool.query(query, params);
    res.json({ documents: result.rows, total: result.rows.length });
  } catch (error) {
    console.error('GET documents error:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

app.post(`${API_PREFIX}/documents`, mutationLimiter, async (req, res) => {
  try {
    const { project_id, doc_type, file_path, content_hash, upstream_hash, created_by } = req.body;
    if (!project_id) return res.status(400).json({ error: 'project_id required' });
    if (!doc_type) return res.status(400).json({ error: 'doc_type required' });
    const result = await pool.query(
      `INSERT INTO pdev_documents (project_id, doc_type, file_path, content_hash, upstream_hash, created_by, modified_by)
       VALUES ($1, $2, $3, $4, $5, $6, $6) RETURNING *`,
      [project_id, doc_type, file_path || null, content_hash || null, upstream_hash || null, created_by || null]
    );
    res.status(201).json(result.rows[0]);
  } catch (error) {
    console.error('POST document error:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

app.put(`${API_PREFIX}/documents/:id`, mutationLimiter, async (req, res) => {
  try {
    const { status, content_hash, upstream_hash, version, modified_by } = req.body;
    const result = await pool.query(
      `UPDATE pdev_documents SET
        status = COALESCE($1, status), content_hash = COALESCE($2, content_hash),
        upstream_hash = COALESCE($3, upstream_hash), version = COALESCE($4, version),
        modified_by = COALESCE($5, modified_by)
      WHERE id = $6 RETURNING *`,
      [status, content_hash, upstream_hash, version, modified_by, req.params.id]
    );
    if (result.rows.length === 0) return res.status(404).json({ error: 'Document not found' });
    res.json(result.rows[0]);
  } catch (error) {
    console.error('PUT document error:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// ============ SESSIONS ============

app.get(`${API_PREFIX}/sessions`, apiLimiter, async (req, res) => {
  try {
    const { project_id, command, status } = req.query;
    let query = 'SELECT * FROM pdev_sessions WHERE 1=1';
    const params = [];
    if (project_id) { params.push(project_id); query += ` AND project_id = $${params.length}`; }
    if (command) { params.push(command); query += ` AND command = $${params.length}`; }
    if (status) { params.push(status); query += ` AND status = $${params.length}`; }
    query += ' ORDER BY started_at DESC';
    const result = await pool.query(query, params);
    res.json({ sessions: result.rows, total: result.rows.length });
  } catch (error) {
    console.error('GET sessions error:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

app.get(`${API_PREFIX}/sessions/:id`, apiLimiter, async (req, res) => {
  try {
    const result = await pool.query('SELECT * FROM pdev_sessions WHERE id = $1', [req.params.id]);
    if (result.rows.length === 0) return res.status(404).json({ error: 'Session not found' });
    res.json(result.rows[0]);
  } catch (error) {
    console.error('GET session error:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

app.post(`${API_PREFIX}/sessions`, mutationLimiter, async (req, res) => {
  try {
    const { project_id, command } = req.body;
    if (!project_id) return res.status(400).json({ error: 'project_id required' });
    if (!command) return res.status(400).json({ error: 'command required' });
    const result = await pool.query(
      'INSERT INTO pdev_sessions (project_id, command) VALUES ($1, $2) RETURNING *',
      [project_id, command]
    );
    res.status(201).json(result.rows[0]);
  } catch (error) {
    console.error('POST session error:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

app.put(`${API_PREFIX}/sessions/:id`, mutationLimiter, async (req, res) => {
  try {
    const { entries, gaps_filled, status } = req.body;
    // Merge entries (append) and gaps_filled (merge objects)
    const current = await pool.query('SELECT entries, gaps_filled FROM pdev_sessions WHERE id = $1', [req.params.id]);
    if (current.rows.length === 0) return res.status(404).json({ error: 'Session not found' });
    
    const newEntries = entries ? [...(current.rows[0].entries || []), ...entries] : current.rows[0].entries;
    const newGaps = gaps_filled ? { ...(current.rows[0].gaps_filled || {}), ...gaps_filled } : current.rows[0].gaps_filled;
    
    const result = await pool.query(
      `UPDATE pdev_sessions SET entries = $1, gaps_filled = $2, status = COALESCE($3, status) WHERE id = $4 RETURNING *`,
      [JSON.stringify(newEntries), JSON.stringify(newGaps), status, req.params.id]
    );
    res.json(result.rows[0]);
  } catch (error) {
    console.error('PUT session error:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

app.put(`${API_PREFIX}/sessions/:id/end`, mutationLimiter, async (req, res) => {
  try {
    const result = await pool.query(
      `UPDATE pdev_sessions SET status = 'completed', ended_at = NOW() WHERE id = $1 RETURNING *`,
      [req.params.id]
    );
    if (result.rows.length === 0) return res.status(404).json({ error: 'Session not found' });
    res.json(result.rows[0]);
  } catch (error) {
    console.error('PUT session end error:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// ============ PIPELINE ============

app.get(`${API_PREFIX}/pipeline/:project_id`, apiLimiter, async (req, res) => {
  try {
    const result = await pool.query(
      'SELECT * FROM pdev_pipeline_status WHERE project_id = $1 ORDER BY stage',
      [req.params.project_id]
    );
    res.json({ stages: result.rows, project_id: req.params.project_id });
  } catch (error) {
    console.error('GET pipeline error:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

app.put(`${API_PREFIX}/pipeline/:project_id/:stage`, mutationLimiter, async (req, res) => {
  try {
    const { health_score, issues } = req.body;
    const result = await pool.query(
      `INSERT INTO pdev_pipeline_status (project_id, stage, health_score, issues, last_validated)
       VALUES ($1, $2, $3, $4, NOW())
       ON CONFLICT (project_id, stage) DO UPDATE SET
         health_score = COALESCE($3, pdev_pipeline_status.health_score),
         issues = COALESCE($4, pdev_pipeline_status.issues),
         last_validated = NOW()
       RETURNING *`,
      [req.params.project_id, req.params.stage, health_score, issues ? JSON.stringify(issues) : null]
    );
    res.json(result.rows[0]);
  } catch (error) {
    console.error('PUT pipeline error:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// ============ CONFLICTS ============

app.get(`${API_PREFIX}/conflicts`, apiLimiter, async (req, res) => {
  try {
    const { project_id, resolved } = req.query;
    let query = 'SELECT * FROM pdev_conflicts WHERE 1=1';
    const params = [];
    if (project_id) { params.push(project_id); query += ` AND project_id = $${params.length}`; }
    if (resolved === 'false') query += ' AND resolved_at IS NULL';
    if (resolved === 'true') query += ' AND resolved_at IS NOT NULL';
    query += ' ORDER BY created_at DESC';
    const result = await pool.query(query, params);
    res.json({ conflicts: result.rows, total: result.rows.length });
  } catch (error) {
    console.error('GET conflicts error:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

app.post(`${API_PREFIX}/conflicts`, mutationLimiter, async (req, res) => {
  try {
    const { project_id, doc_a_id, doc_b_id, conflict_type, description } = req.body;
    if (!project_id) return res.status(400).json({ error: 'project_id required' });
    const result = await pool.query(
      `INSERT INTO pdev_conflicts (project_id, doc_a_id, doc_b_id, conflict_type, description)
       VALUES ($1, $2, $3, $4, $5) RETURNING *`,
      [project_id, doc_a_id || null, doc_b_id || null, conflict_type || null, description || null]
    );
    res.status(201).json(result.rows[0]);
  } catch (error) {
    console.error('POST conflict error:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

app.put(`${API_PREFIX}/conflicts/:id`, mutationLimiter, async (req, res) => {
  try {
    const { resolution } = req.body;
    const result = await pool.query(
      `UPDATE pdev_conflicts SET resolution = $1, resolved_at = NOW() WHERE id = $2 RETURNING *`,
      [resolution, req.params.id]
    );
    if (result.rows.length === 0) return res.status(404).json({ error: 'Conflict not found' });
    res.json(result.rows[0]);
  } catch (error) {
    console.error('PUT conflict error:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// ============ STATS ============

app.get(`${API_PREFIX}/stats`, apiLimiter, async (req, res) => {
  try {
    const [projects, documents, sessions, conflicts] = await Promise.all([
      pool.query('SELECT COUNT(*) as count FROM pdev_projects WHERE is_archived = false'),
      pool.query('SELECT COUNT(*) as count FROM pdev_documents'),
      pool.query('SELECT COUNT(*) as count FROM pdev_sessions WHERE status = $1', ['active']),
      pool.query('SELECT COUNT(*) as count FROM pdev_conflicts WHERE resolved_at IS NULL'),
    ]);
    res.json({
      projects: parseInt(projects.rows[0].count),
      documents: parseInt(documents.rows[0].count),
      active_sessions: parseInt(sessions.rows[0].count),
      unresolved_conflicts: parseInt(conflicts.rows[0].count),
    });
  } catch (error) {
    console.error('GET stats error:', error);
    res.status(500).json({ error: 'Internal server error' });
  }
});

// 404 handler
app.use((req, res) => {
  res.status(404).json({ error: 'Not found', path: req.path, method: req.method });
});

// Error handler
app.use((err, req, res, next) => {
  console.error('Unhandled error:', err);
  res.status(500).json({ error: 'Internal server error' });
});

// Start server
const PORT = process.env.PORT || 3022;
const server = app.listen(PORT, () => {
  console.log(`PDev API running on port ${PORT}`);
});

// Graceful shutdown
process.on('SIGTERM', async () => {
  console.log('SIGTERM received, shutting down...');
  server.close(async () => {
    await pool.end();
    console.log('Pool closed, exiting');
    process.exit(0);
  });
});
