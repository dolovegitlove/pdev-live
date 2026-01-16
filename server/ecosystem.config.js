// PM2 Ecosystem Config - Standardized with Restart Protection
const baseDir = process.env.PDEV_SERVER_DIR || '/opt/services/pdev-live';

module.exports = {
  apps: [{
    name: 'pdev-live',
    script: 'server.js',
    cwd: baseDir,
    exec_mode: 'fork',
    instances: 1,

    // Restart Policy (Prevents infinite loops + DB-001 compliance)
    autorestart: true,
    max_restarts: 10,
    min_uptime: '60s',
    restart_delay: 4000,
    exp_backoff_restart_delay: 30000,

    // Timeouts
    kill_timeout: 5000,
    listen_timeout: 10000,

    // Development Environment
    env: {
      NODE_ENV: 'development'
      // PORT loaded from .env via dotenv.config()
      // PDEV_ADMIN_KEY must be set in .env file - NEVER hardcode secrets
    },

    // Production Environment
    env_production: {
      NODE_ENV: 'production'
      // PORT loaded from .env via dotenv.config()
      // PDEV_ADMIN_KEY must be set in .env file - NEVER hardcode secrets
    },

    // Logging (absolute paths for reliability)
    error_file: '/opt/services/pdev-live/logs/error.log',
    out_file: '/opt/services/pdev-live/logs/out.log',
    merge_logs: true,
    log_date_format: 'YYYY-MM-DD HH:mm:ss Z',

    // Performance
    max_memory_restart: '500M',

    // Process Management
    watch: false,

    // Metadata
    version: '3.0.1'
  }]
};
