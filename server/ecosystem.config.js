// PM2 Ecosystem Config - Standardized with Restart Protection
module.exports = {
  apps: [{
    name: 'pdev-live',
    script: 'server.js',
    cwd: '/opt/services/pdev-live',
    exec_mode: 'fork',
    instances: 1,

    // Restart Policy (Prevents infinite loops)
    autorestart: true,
    max_restarts: 10,
    min_uptime: '60s',
    exp_backoff_restart_delay: 30000,

    // Timeouts
    kill_timeout: 5000,
    listen_timeout: 10000,

    // Environment
    env: {
      NODE_ENV: 'production',
      PORT: 3016,
      PDEV_ADMIN_KEY: '5CG0k5JOyBmd//v8xqTDzKbJlSwXImB6y91SErZWfd0='
    },

    // Logging
    error_file: '/opt/services/pdev-live/logs/error.log',
    out_file: '/opt/services/pdev-live/logs/out.log',
    merge_logs: true,
    log_date_format: 'YYYY-MM-DD HH:mm:ss Z',

    // Performance
    max_memory_restart: '500M',

    // Process Management
    watch: false,

    // Metadata
    version: '3.0.0'
  }]
};
