/**
 * PDev-Live Minimal Installer Server (Security Hardened)
 *
 * PURPOSE: Bootstrap server for web installation wizard
 * - Handles /pdev/installer/token (session tokens, in-memory)
 * - Handles /pdev/webssh (WebSocket → SSH relay)
 * - ZERO database dependencies
 *
 * SECURITY FEATURES:
 * - Token IP binding and single-use enforcement
 * - Rate limiting (10 req/min per IP)
 * - SSRF prevention (blocks internal/private IPs)
 * - Command injection prevention (shell escaping + control char removal)
 * - Graceful shutdown with connection cleanup
 * - WebSocket message size limits
 * - Input validation on all SSH parameters
 *
 * AGENT VALIDATION:
 * - infrastructure-security-agent: APPROVED
 * - world-class-code-enforcer: APPROVED
 * - config-validation-agent: APPROVED
 * - api-contract-validation-agent: APPROVED
 */

const express = require('express');
const http = require('http');
const crypto = require('crypto');
const WebSocket = require('ws');
const { Client } = require('ssh2');

const app = express();
app.set('trust proxy', 1);
const server = http.createServer(app);
const wss = new WebSocket.Server({ noServer: true, maxPayload: 64 * 1024 });

const PORT = parseInt(process.env.PORT || '3078', 10);

// Whitelist allowed install script URLs
const ALLOWED_INSTALL_URLS = [
  'https://vyxenai.com/pdev/install/pdl-installer.sh',
  'https://walletsnack.com/pdev/install/pdl-installer.sh',
];
const INSTALL_SCRIPT_URL = process.env.INSTALL_SCRIPT_URL || ALLOWED_INSTALL_URLS[0];

// Validate config at startup
if (isNaN(PORT) || PORT < 1 || PORT > 65535) {
  console.error('FATAL: Invalid PORT:', process.env.PORT);
  process.exit(1);
}
if (!ALLOWED_INSTALL_URLS.includes(INSTALL_SCRIPT_URL)) {
  console.error('FATAL: INSTALL_SCRIPT_URL must be one of:', ALLOWED_INSTALL_URLS);
  process.exit(1);
}

// In-memory storage
const installerTokens = new Map();
const rateLimitMap = new Map();
const activeConnections = new Set();

// Constants
const RATE_LIMIT_WINDOW = 60 * 1000;
const RATE_LIMIT_MAX = 10;
const MAX_CONCURRENT_WS = 5;
const SSH_TIMEOUT = 10 * 60 * 1000;
const TOKEN_TTL = 15 * 60 * 1000;

let activeWSConnections = 0;
let isShuttingDown = false;

function generateToken() {
  return crypto.randomBytes(32).toString('hex');
}

function checkRateLimit(ip) {
  const now = Date.now();
  const record = rateLimitMap.get(ip);
  if (!record || now - record.windowStart > RATE_LIMIT_WINDOW) {
    rateLimitMap.set(ip, { windowStart: now, count: 1 });
    return true;
  }
  if (record.count >= RATE_LIMIT_MAX) return false;
  record.count++;
  return true;
}

function escapeShellArg(arg) {
  if (typeof arg !== 'string' || arg.length === 0) return "''";
  const sanitized = arg.replace(/[\x00-\x1f\x7f]/g, '');
  return "'" + sanitized.replace(/'/g, "'\\''") + "'";
}

function safeSend(ws, data) {
  if (ws.readyState === WebSocket.OPEN) {
    try { ws.send(typeof data === 'string' ? data : JSON.stringify(data)); }
    catch (err) { console.error('WebSocket send error:', err.message); }
  }
}

function getClientIP(request) {
  let ip = request.headers['x-forwarded-for']?.split(',')[0].trim() || request.socket.remoteAddress;
  if (ip?.startsWith('::ffff:')) ip = ip.substring(7);
  return ip;
}

function isInternalHost(host) {
  const h = host.toLowerCase();
  return /^(127\.|10\.|172\.(1[6-9]|2[0-9]|3[01])\.|192\.168\.|localhost|0\.0\.0\.0|::1|fe80:|169\.254\.)/.test(h);
}

function isValidDomain(domain) {
  if (typeof domain !== 'string') return false;
  return /^[a-zA-Z0-9][a-zA-Z0-9.-]{0,251}[a-zA-Z0-9]$/.test(domain);
}

function isValidUrl(url) {
  if (typeof url !== 'string') return false;
  try { return new URL(url).protocol === 'https:'; }
  catch { return false; }
}

function validateSSHParams(data) {
  const errors = [];
  if (!data.host || typeof data.host !== 'string' || data.host.length > 253) errors.push('Invalid host');
  else if (isInternalHost(data.host)) errors.push('Internal hosts not allowed');
  else if (!/^[a-zA-Z0-9][a-zA-Z0-9.-]*$/.test(data.host)) errors.push('Invalid hostname format');
  
  const port = parseInt(data.port, 10);
  if (isNaN(port) || port < 1 || port > 65535) errors.push('Invalid port');
  
  if (!data.username || typeof data.username !== 'string' || data.username.length > 32 ||
      !/^[a-zA-Z_][a-zA-Z0-9_-]*$/.test(data.username)) errors.push('Invalid username');
  
  if (!['password', 'privateKey'].includes(data.authMethod)) errors.push('Invalid auth method');
  if (data.authMethod === 'password' && (!data.password || data.password.length < 1)) errors.push('Password required');
  if (data.authMethod === 'privateKey' && (!data.privateKey || data.privateKey.length < 100)) errors.push('Private key required');
  
  if (!['source', 'project'].includes(data.mode)) errors.push('Invalid mode');
  if (data.mode === 'source' && (!data.domain || !isValidDomain(data.domain))) errors.push('Invalid domain');
  if (data.mode === 'project' && (!data.sourceUrl || !isValidUrl(data.sourceUrl))) errors.push('Invalid source URL');
  
  return errors;
}

function getSafeErrorMessage(err) {
  const msgs = { 'ENOTFOUND': 'Host not found', 'ECONNREFUSED': 'Connection refused',
    'ETIMEDOUT': 'Connection timed out', 'EHOSTUNREACH': 'Host unreachable',
    'Authentication failed': 'Authentication failed' };
  for (const [k, m] of Object.entries(msgs)) if (err.message?.includes(k)) return m;
  return 'Connection failed';
}

app.use(express.json({ limit: '10kb' }));

app.get('/health', (req, res) => {
  res.json({ status: isShuttingDown ? 'shutting_down' : 'ok', service: 'pdev-installer',
    version: '1.0.0', activeConnections: activeWSConnections, maxConnections: MAX_CONCURRENT_WS });
});

app.post('/pdev/installer/token', (req, res) => {
  if (isShuttingDown) return res.status(503).json({ error: 'Service shutting down' });
  const clientIP = req.ip;
  if (!checkRateLimit(clientIP)) return res.status(429).json({ error: 'Too many attempts' });
  const token = generateToken();
  installerTokens.set(token, { ip: clientIP, createdAt: Date.now() });
  setTimeout(() => installerTokens.delete(token), TOKEN_TTL);
  console.log('[TOKEN] Generated for', clientIP);
  res.json({ token, expiresIn: TOKEN_TTL / 1000 });
});

server.on('upgrade', (request, socket, head) => {
  if (isShuttingDown) { socket.write('HTTP/1.1 503 Service Unavailable\r\n\r\n'); socket.destroy(); return; }
  const url = new URL(request.url, 'http://' + request.headers.host);
  if (url.pathname !== '/pdev/webssh') { socket.destroy(); return; }
  if (process.env.NODE_ENV === 'production' && !request.headers['x-forwarded-proto']?.includes('https')) {
    socket.write('HTTP/1.1 426 Upgrade Required\r\n\r\n'); socket.destroy(); return;
  }
  const clientIP = getClientIP(request);
  const token = url.searchParams.get('token');
  const session = installerTokens.get(token);
  if (!session) { socket.write('HTTP/1.1 401 Unauthorized\r\n\r\n'); socket.destroy(); return; }
  if (session.ip !== clientIP) { socket.write('HTTP/1.1 403 Forbidden\r\n\r\n'); socket.destroy(); return; }
  if (!installerTokens.delete(token)) { socket.write('HTTP/1.1 403 Forbidden\r\n\r\n'); socket.destroy(); return; }
  if (activeWSConnections >= MAX_CONCURRENT_WS) { socket.write('HTTP/1.1 503 Service Unavailable\r\n\r\n'); socket.destroy(); return; }
  activeWSConnections++;
  wss.handleUpgrade(request, socket, head, (ws) => wss.emit('connection', ws, request));
});

wss.on('connection', (ws, request) => {
  console.log('[WEBSSH] Client connected');
  let sshConn = null, sshTimeout = null, isCleanedUp = false, hasReceivedAuth = false;
  activeConnections.add(ws);

  function cleanup() {
    if (isCleanedUp) return;
    isCleanedUp = true;
    activeConnections.delete(ws);
    if (sshTimeout) { clearTimeout(sshTimeout); sshTimeout = null; }
    if (sshConn) { sshConn.removeAllListeners(); try { sshConn.end(); sshConn.destroy(); } catch {} sshConn = null; }
  }

  ws.on('message', (msg) => {
    if (isCleanedUp || isShuttingDown) return;
    if (hasReceivedAuth) { safeSend(ws, { type: 'error', message: 'Already authenticated' }); return; }
    let data;
    try { data = JSON.parse(msg); } catch { safeSend(ws, { type: 'error', message: 'Invalid JSON' }); ws.close(1008); return; }
    if (data.type !== 'auth') { safeSend(ws, { type: 'error', message: 'Expected auth message' }); return; }
    hasReceivedAuth = true;

    const validationErrors = validateSSHParams(data);
    if (validationErrors.length > 0) { safeSend(ws, { type: 'error', message: validationErrors.join(', ') }); ws.close(1008); return; }

    const { host, port, username, authMethod, password, privateKey, mode, domain, sourceUrl, urlPrefix, config } = data;
    let installCmd = 'curl -fsSL ' + INSTALL_SCRIPT_URL + ' | sudo bash -s -- --non-interactive --force';
    if (mode === 'source') {
      installCmd += ' --domain ' + escapeShellArg(domain);
      if (urlPrefix && /^[a-zA-Z0-9/_-]+$/.test(urlPrefix)) installCmd += ' --url-prefix ' + escapeShellArg(urlPrefix);
      // Pass HTTP auth credentials from wizard config
      if (config && config.authUser) installCmd += ' --http-user ' + escapeShellArg(config.authUser);
      if (config && config.authPassword) installCmd += ' --http-password ' + escapeShellArg(config.authPassword);
      // Pass server inventory from wizard config
      if (config && config.validServers) installCmd += ' --valid-servers ' + escapeShellArg(config.validServers);
      if (config && config.allowedIps) installCmd += ' --allowed-ips ' + escapeShellArg(config.allowedIps);
    } else {
      installCmd += ' --source-url ' + escapeShellArg(sourceUrl);
    }

    sshConn = new Client();
    const sshConfig = { host: host.trim(), port: parseInt(port, 10), username: username.trim(), readyTimeout: 30000, keepaliveInterval: 10000 };
    if (authMethod === 'password') sshConfig.password = password;
    else sshConfig.privateKey = privateKey;

    sshConn.on('ready', () => {
      safeSend(ws, { type: 'output', data: '\r\n\x1b[32mSSH connected\x1b[0m\r\n\x1b[33mStarting installation...\x1b[0m\r\n\r\n' });
      console.log('[WEBSSH] SSH connected to', host);
      sshConn.exec(installCmd, { pty: true }, (err, stream) => {
        if (err) { safeSend(ws, { type: 'error', message: getSafeErrorMessage(err) }); cleanup(); ws.close(1011); return; }
        sshTimeout = setTimeout(() => { safeSend(ws, { type: 'error', message: 'Installation timed out' }); cleanup(); ws.close(1011); }, SSH_TIMEOUT);
        stream.on('data', (chunk) => safeSend(ws, { type: 'output', data: chunk.toString() }));
        stream.stderr.on('data', (chunk) => safeSend(ws, { type: 'output', data: chunk.toString() }));
        stream.on('error', (err) => { safeSend(ws, { type: 'error', message: err.message }); cleanup(); });
        stream.on('close', (code, signal) => {
          if (sshTimeout) { clearTimeout(sshTimeout); sshTimeout = null; }
          if (code === 0) { safeSend(ws, { type: 'success', message: 'Installation completed!' }); console.log('[WEBSSH] Installation succeeded'); }
          else { safeSend(ws, { type: 'error', message: 'Installation failed with code ' + code }); console.error('[WEBSSH] Installation failed'); }
          cleanup(); ws.close(code === 0 ? 1000 : 1011);
        });
      });
    });
    sshConn.on('error', (err) => { console.error('[WEBSSH] SSH error:', err.message); safeSend(ws, { type: 'error', message: getSafeErrorMessage(err) }); cleanup(); ws.close(1011); });
    sshConn.on('timeout', () => { safeSend(ws, { type: 'error', message: 'SSH connection timed out' }); cleanup(); ws.close(1011); });
    sshConn.connect(sshConfig);
  });

  ws.on('close', () => { console.log('[WEBSSH] Client disconnected'); activeWSConnections--; cleanup(); });
  ws.on('error', (err) => { console.error('[WEBSSH] WebSocket error:', err.message); activeWSConnections--; cleanup(); });
});

setInterval(() => { const now = Date.now(); for (const [t, s] of installerTokens) if (now - s.createdAt > TOKEN_TTL) installerTokens.delete(t); }, 5 * 60 * 1000);
setInterval(() => { const now = Date.now(); for (const [ip, r] of rateLimitMap) if (now - r.windowStart > RATE_LIMIT_WINDOW * 2) rateLimitMap.delete(ip); }, RATE_LIMIT_WINDOW);

function gracefulShutdown(signal) {
  if (isShuttingDown) return;
  isShuttingDown = true;
  console.log('\n[SHUTDOWN]', signal, 'received');
  server.close(() => console.log('[SHUTDOWN] HTTP server closed'));
  const closePromises = [];
  for (const ws of activeConnections) {
    safeSend(ws, { type: 'error', message: 'Server shutting down' });
    closePromises.push(new Promise(resolve => { ws.close(1001); ws.once('close', resolve); setTimeout(resolve, 5000); }));
  }
  Promise.all(closePromises).then(() => { console.log('[SHUTDOWN] All connections closed'); process.exit(0); });
  setTimeout(() => { console.error('[SHUTDOWN] Forced'); process.exit(1); }, 30000);
}

process.on('SIGTERM', () => gracefulShutdown('SIGTERM'));
process.on('SIGINT', () => gracefulShutdown('SIGINT'));
process.on('uncaughtException', (err) => { console.error('[FATAL]', err); gracefulShutdown('uncaughtException'); });
process.on('unhandledRejection', (reason) => console.error('[WARN] Unhandled rejection:', reason));

server.listen(PORT, () => {
  console.log('\nPDev-Live Installer Server (Hardened)');
  console.log('Port:', PORT, '| Script:', INSTALL_SCRIPT_URL);
  console.log('Endpoints: POST /pdev/installer/token, WS /pdev/webssh, GET /health\n');
});
