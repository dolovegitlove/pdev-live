-- Migration: 003_create_server_tokens
-- Purpose: Add server tokens table for CLI client authentication

-- Create server_tokens table for CLI client authentication
CREATE TABLE IF NOT EXISTS server_tokens (
  id SERIAL PRIMARY KEY,
  server_name VARCHAR(50) NOT NULL UNIQUE,
  token VARCHAR(64) NOT NULL UNIQUE,
  created_at TIMESTAMP DEFAULT NOW(),
  last_used_at TIMESTAMP,
  revoked_at TIMESTAMP
);

-- Index for fast token lookups (only active tokens)
CREATE INDEX IF NOT EXISTS idx_server_tokens_token ON server_tokens(token) WHERE revoked_at IS NULL;

-- Index for server lookup
CREATE INDEX IF NOT EXISTS idx_server_tokens_server ON server_tokens(server_name) WHERE revoked_at IS NULL;

-- Record migration
INSERT INTO pdev_migrations (migration_name) VALUES ('003_create_server_tokens')
ON CONFLICT (migration_name) DO NOTHING;
