// PM2 Ecosystem Config - PDev Installer Server
module.exports = {
  apps: [{
    name: 'pdev-installer',
    script: 'installer-server.js',
    cwd: '/opt/services/pdev-installer',
    exec_mode: 'fork',
    instances: 1,

    // Restart Policy
    autorestart: true,
    max_restarts: 10,
    min_uptime: '30s',
    exp_backoff_restart_delay: 5000,

    // Timeouts
    kill_timeout: 5000,
    listen_timeout: 10000,

    // Environment
    env: {
      NODE_ENV: 'production',
      PORT: 3078,
      SOURCE_AUTH_USER: 'pdev',
      SOURCE_AUTH_PASSWORD: 'PdevLive0987@@'
    },

    // Logging
    error_file: '/opt/services/pdev-installer/logs/error.log',
    out_file: '/opt/services/pdev-installer/logs/out.log',
    merge_logs: true,
    log_date_format: 'YYYY-MM-DD HH:mm:ss Z',

    // Performance
    max_memory_restart: '200M',

    // No watch in production
    watch: false,

    version: '1.0.0'
  }]
};
