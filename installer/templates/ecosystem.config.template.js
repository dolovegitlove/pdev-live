/**
 * PM2 Ecosystem Config Template - Reusable Installer Template
 *
 * Template Variables (REQUIRED - substitute before deployment):
 * - {{SERVICE_NAME}}   : PM2 process name (e.g., "vyxenai-installer")
 * - {{INSTALL_PATH}}   : Installation directory absolute path (e.g., "/opt/services/vyxenai-installer/server")
 * - {{VERSION}}        : Version string (e.g., "1.0.0")
 * - {{PORT}}           : HTTP server port (e.g., "3078")
 *
 * Substitution Command:
 *   sed -e "s|{{SERVICE_NAME}}|$SERVICE_NAME|g" \
 *       -e "s|{{INSTALL_PATH}}|$INSTALL_PATH|g" \
 *       -e "s|{{VERSION}}|$VERSION|g" \
 *       -e "s|{{PORT}}|$PORT|g" \
 *       ecosystem.config.template.js > ecosystem.config.js
 *
 * Pre-Deployment Checklist:
 * 1. Create logs directory: mkdir -p {{INSTALL_PATH}}/logs
 * 2. Create .env file with required variables (PORT, PDEV_ADMIN_KEY, DB credentials)
 * 3. Validate syntax: node -c ecosystem.config.js
 * 4. Test PM2 config: pm2 start ecosystem.config.js --dry-run
 * 5. Health check after start: curl http://localhost:{{PORT}}/health
 */

module.exports = {
  apps: [{
    name: '{{SERVICE_NAME}}',
    script: 'server.js',
    cwd: '{{INSTALL_PATH}}',
    exec_mode: 'fork',
    instances: 1,

    // Restart Policy (Prevents infinite restart loops - DB-001 compliance)
    autorestart: true,
    max_restarts: 10,           // Stop restarting after 10 failures
    min_uptime: '60s',          // Must run 60s to count as successful start
    restart_delay: 4000,        // 4s delay between restarts (DB-001 requirement)
    exp_backoff_restart_delay: 30000,  // Exponential backoff starting at 30s

    // Timeouts
    kill_timeout: 5000,         // 5s graceful shutdown timeout
    listen_timeout: 10000,      // 10s startup timeout
    wait_ready: true,           // Wait for app to emit 'ready' signal
    shutdown_with_message: true, // Send shutdown message to app

    // Node.js Options
    node_args: '--max-old-space-size=450', // Align with max_memory_restart

    // Environment
    env: {
      NODE_ENV: 'production',
      PORT: '{{PORT}}'
      // REQUIRED ENV VARS (must be in {{INSTALL_PATH}}/.env file):
      // - PDEV_ADMIN_KEY: Admin API key (min 32 chars)
      // - PDEV_DB_HOST: Database hostname
      // - PDEV_DB_USER: Database username
      // - PDEV_DB_NAME: Database name
      // - PDEV_DB_PASSWORD: Database password
      // - PDEV_BASE_URL: Public-facing URL
      // CRITICAL: NEVER hardcode secrets in this file - use .env only
    },

    // Logging (INSTALLER MUST CREATE {{INSTALL_PATH}}/logs/ directory)
    error_file: '{{INSTALL_PATH}}/logs/error.log',
    out_file: '{{INSTALL_PATH}}/logs/out.log',
    merge_logs: true,
    combine_logs: true,
    time: true,
    log_date_format: 'YYYY-MM-DD HH:mm:ss Z',

    // Performance (DB-001 memory leak prevention)
    max_memory_restart: '500M', // Restart before OOM - reduce to 300M for lightweight services

    // Process Management
    watch: false,               // NEVER enable in production
    // cron_restart: '0 3 * * *',  // Optional: daily 3am restart for leak mitigation

    // Metadata
    version: '{{VERSION}}'
  }]
};
