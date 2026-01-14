/**
 * PDev-Live Configuration Module
 * Central configuration for server.js
 *
 * Environment variables loaded via dotenv.config() in server.js
 */

module.exports = {
  // API Configuration
  api: {
    port: parseInt(process.env.PORT || '3016', 10)
  },

  // Server Validation
  servers: {
    valid: (process.env.PDEV_VALID_SERVERS || 'acme,ittz,cfree,djm,wdress,rmlve,dolovdev')
      .split(',')
      .map(s => s.trim())
      .filter(s => s.length > 0)
  },

  // Partner Configuration
  partner: {
    serverName: process.env.PDEV_SERVER_NAME || 'partner'
  }
};
