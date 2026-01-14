// PM2 Ecosystem Config - PDev Installer Server
const baseDir = process.env.PDEV_INSTALLER_DIR || '/opt/services/pdev-installer';

module.exports = {
  apps: [{
    name: 'pdev-installer',
    script: 'installer-server.js',
    cwd: baseDir,
    exec_mode: 'fork',
    instances: 1,

    // Restart Policy (DB-001 compliance)
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
      NODE_ENV: 'development',
      PORT: parseInt(process.env.INSTALLER_PORT, 10) || 3078
    },

    // Production Environment
    env_production: {
      NODE_ENV: 'production',
      PORT: parseInt(process.env.INSTALLER_PORT, 10) || 3078
    },

    // Logging
    error_file: baseDir + '/logs/error.log',
    out_file: baseDir + '/logs/out.log',
    merge_logs: true,
    log_date_format: 'YYYY-MM-DD HH:mm:ss Z',

    // Performance
    max_memory_restart: '200M',

    // No watch in production
    watch: false,

    version: '1.0.1'
  }]
};
