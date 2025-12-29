module.exports = {
  apps: [{
    name: 'pdev-api',
    script: 'index.js',
    cwd: '/home/acme/pdev-api',
    exec_mode: 'fork',
    instances: 1,
    autorestart: true,
    max_restarts: 10,
    min_uptime: '60s',
    exp_backoff_restart_delay: 30000,
    kill_timeout: 5000,
    listen_timeout: 10000,
    env: {
      NODE_ENV: 'production',
      PORT: 3022
    },
    error_file: '/home/acme/pdev-api/logs/error.log',
    out_file: '/home/acme/pdev-api/logs/out.log',
    merge_logs: true,
    log_date_format: 'YYYY-MM-DD HH:mm:ss Z',
    max_memory_restart: '500M',
    watch: false,
    version: '1.0.0'
  }]
};
