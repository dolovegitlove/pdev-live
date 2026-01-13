/**
 * PDev-Live Configuration Loader
 * Centralizes all environment-specific configuration
 * Supports .env files and environment variable overrides
 */

const fs = require('fs');
const path = require('path');

/**
 * Load .env file if it exists
 */
function loadEnvFile() {
  const envPath = path.join(__dirname, '.env');

  if (!fs.existsSync(envPath)) {
    console.warn('[CONFIG] No .env file found, using defaults or environment variables');
    return;
  }

  const envContent = fs.readFileSync(envPath, 'utf8');
  const lines = envContent.split('\n');

  lines.forEach(line => {
    line = line.trim();

    // Skip comments and empty lines
    if (!line || line.startsWith('#')) return;

    const match = line.match(/^([A-Z_][A-Z0-9_]*)=(.*)$/);
    if (!match) return;

    const key = match[1];
    let value = match[2];

    // Remove quotes if present
    if ((value.startsWith('"') && value.endsWith('"')) ||
        (value.startsWith("'") && value.endsWith("'"))) {
      value = value.slice(1, -1);
    }

    // Expand ${VAR} references
    value = value.replace(/\$\{([A-Z_][A-Z0-9_]*)\}/g, (_, varName) => {
      return process.env[varName] || '';
    });

    // Only set if not already in environment
    if (!process.env[key]) {
      process.env[key] = value;
    }
  });
}

// Load .env on module import
loadEnvFile();

/**
 * Get configuration value with fallback
 */
function get(key, defaultValue = null) {
  return process.env[key] || defaultValue;
}

/**
 * Get required configuration value (throws if missing)
 */
function getRequired(key) {
  const value = process.env[key];
  if (!value) {
    throw new Error(`Missing required configuration: ${key}`);
  }
  return value;
}

/**
 * Get boolean configuration value
 */
function getBoolean(key, defaultValue = false) {
  const value = get(key);
  if (!value) return defaultValue;
  return ['true', '1', 'yes', 'on'].includes(value.toLowerCase());
}

/**
 * Get integer configuration value
 */
function getInt(key, defaultValue = 0) {
  const value = get(key);
  if (!value) return defaultValue;
  const parsed = parseInt(value, 10);
  return isNaN(parsed) ? defaultValue : parsed;
}

/**
 * Get array configuration value (comma-separated)
 */
function getArray(key, defaultValue = []) {
  const value = get(key);
  if (!value) return defaultValue;
  return value.split(',').map(v => v.trim()).filter(Boolean);
}

/**
 * Configuration object
 */
const config = {
  // Partner identity
  partner: {
    domain: get('PARTNER_DOMAIN', 'walletsnack.com'),
    name: get('PARTNER_NAME', 'PDev Suite'),
    serverName: get('PARTNER_SERVER_NAME', 'acme'),
    timezone: get('PARTNER_TIMEZONE', 'America/New_York'),
  },

  // API configuration
  api: {
    url: get('PDEV_LIVE_URL', 'https://walletsnack.com/pdev/api'),
    baseUrl: get('PDEV_BASE_URL', 'https://walletsnack.com/pdev'),
    port: getInt('PDEV_API_PORT', 3077),
    host: get('PDEV_API_HOST', '0.0.0.0'),
  },

  // Server inventory
  servers: {
    valid: getArray('VALID_SERVERS', ['dolovdev', 'acme', 'ittz', 'dolov', 'wdress', 'cfree', 'rmlve', 'djm']),
    allowedIps: getArray('ALLOWED_IPS', [
      '127.0.0.1',
      '::1',
      // Legacy production IPs (override via ALLOWED_IPS in .env for new deployments)
      '194.32.107.30',   // Production server 1
      '185.125.171.10',  // Production server 2
      '185.125.168.113', // Production server 3
      '185.14.97.38',    // Production server 4
      '98.156.21.66',    // Production server 5
      '50.28.110.188',   // Production server 6
      '174.246.135.142', // Production server 7
    ]),
  },

  // Database configuration (uses PDEV_DB_* prefix to match server.js Pool)
  database: {
    host: get('PDEV_DB_HOST', 'localhost'),
    port: getInt('PDEV_DB_PORT', 5432),
    name: get('PDEV_DB_NAME', 'pdev_live'),
    user: get('PDEV_DB_USER', 'pdev_app'),
    password: get('PDEV_DB_PASSWORD'),
    connectionString: get('DATABASE_URL') ||
      `postgresql://${get('PDEV_DB_USER', 'pdev_app')}:${get('PDEV_DB_PASSWORD')}@${get('PDEV_DB_HOST', 'localhost')}:${getInt('PDEV_DB_PORT', 5432)}/${get('PDEV_DB_NAME', 'pdev_live')}`,
  },

  // Deployment paths
  deployment: {
    user: get('DEPLOY_USER', 'acme'),
    frontendPath: get('FRONTEND_DEPLOY_PATH', '/var/www/vyxenai.com/pdev'),
    backupPath: get('FRONTEND_BACKUP_PATH', '/var/www/vyxenai.com/pdev-backups'),
    servicePath: get('BACKEND_SERVICE_PATH', '/opt/services/pdev-live'),
    logPath: get('LOG_PATH', '/opt/services/pdev-live/logs'),
  },

  // SSL/TLS configuration
  ssl: {
    certPath: get('SSL_CERT_PATH', `/etc/letsencrypt/live/${get('PARTNER_DOMAIN', 'walletsnack.com')}/fullchain.pem`),
    keyPath: get('SSL_KEY_PATH', `/etc/letsencrypt/live/${get('PARTNER_DOMAIN', 'walletsnack.com')}/privkey.pem`),
  },

  // Authentication
  auth: {
    user: get('PDEV_AUTH_USER', 'pdev'),
    password: get('PDEV_AUTH_PASSWORD'),
    sessionSecret: get('SESSION_SECRET', 'change-me-in-production'),
  },

  // Desktop client
  desktop: {
    homepage: get('DESKTOP_HOMEPAGE', 'https://walletsnack.com/pdev/live/'),
    updateUrl: get('DESKTOP_UPDATE_URL', 'https://walletsnack.com/pdev/releases/'),
  },

  // Feature flags
  features: {
    autoUpdates: getBoolean('ENABLE_AUTO_UPDATES', true),
    telemetry: getBoolean('ENABLE_TELEMETRY', false),
    debugMode: getBoolean('ENABLE_DEBUG_MODE', false),
  },

  // Backup retention
  backup: {
    keepDays: getInt('BACKUP_KEEP_DAYS', 30),
    maxCount: getInt('BACKUP_MAX_COUNT', 10),
  },

  // PM2 configuration
  pm2: {
    appName: get('PM2_APP_NAME', 'pdev-live'),
    instances: getInt('PM2_INSTANCES', 1),
    maxMemoryRestart: get('PM2_MAX_MEMORY_RESTART', '512M'),
  },

  // Environment
  env: get('NODE_ENV', 'production'),
  isDevelopment: get('NODE_ENV') === 'development',
  isProduction: get('NODE_ENV') === 'production',
};

// Validation warnings
if (config.isProduction) {
  if (config.auth.sessionSecret === 'change-me-in-production') {
    console.warn('[CONFIG] WARNING: Using default SESSION_SECRET in production!');
  }
  if (!config.auth.password) {
    console.warn('[CONFIG] WARNING: No PDEV_AUTH_PASSWORD set for HTTP Basic Auth!');
  }
  if (!config.database.password) {
    console.warn('[CONFIG] WARNING: No PDEV_DB_PASSWORD set for database connection!');
  }
}

module.exports = config;
module.exports.get = get;
module.exports.getRequired = getRequired;
module.exports.getBoolean = getBoolean;
module.exports.getInt = getInt;
module.exports.getArray = getArray;
