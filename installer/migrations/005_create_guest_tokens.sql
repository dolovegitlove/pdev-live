-- Migration: 005_create_guest_tokens
-- Purpose: Persist guest tokens to database for crash recovery and multi-instance support
-- Date: 2026-01-08

BEGIN;

-- Create guest_tokens table
CREATE TABLE IF NOT EXISTS guest_tokens (
  id SERIAL PRIMARY KEY,
  token VARCHAR(64) NOT NULL UNIQUE,

  -- Token type discriminator
  token_type VARCHAR(20) NOT NULL DEFAULT 'session' CHECK (token_type IN ('session', 'project')),

  -- Session-specific token fields
  session_id UUID REFERENCES pdev_sessions(id) ON DELETE CASCADE,

  -- Project-wide token fields
  server_name VARCHAR(100),
  project_name VARCHAR(255),

  -- Common fields
  expires_at TIMESTAMP WITH TIME ZONE NOT NULL,
  created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
  created_by VARCHAR(100),

  -- Enforce type-specific constraints
  CONSTRAINT session_token_has_session_id
    CHECK (token_type != 'session' OR session_id IS NOT NULL),
  CONSTRAINT project_token_has_metadata
    CHECK (token_type != 'project' OR (server_name IS NOT NULL AND project_name IS NOT NULL))
);

-- Performance indexes

-- Fast token lookup (primary use case - token is unique, no partial index needed)
CREATE INDEX idx_guest_tokens_token_active
  ON guest_tokens(token);

-- Cleanup query optimization (find expired tokens - no WHERE clause, filter at query time)
CREATE INDEX idx_guest_tokens_expires
  ON guest_tokens(expires_at);

-- Session cascade delete optimization
CREATE INDEX idx_guest_tokens_session
  ON guest_tokens(session_id)
  WHERE session_id IS NOT NULL;

-- Project token lookup optimization
CREATE INDEX idx_guest_tokens_project
  ON guest_tokens(server_name, project_name, expires_at)
  WHERE token_type = 'project';

-- Admin panel queries (list active guest links - filter at query time)
CREATE INDEX idx_guest_tokens_created
  ON guest_tokens(created_at DESC);

-- Grant permissions to pdev_app user
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE guest_tokens TO pdev_app;
GRANT USAGE, SELECT ON SEQUENCE guest_tokens_id_seq TO pdev_app;

-- Record migration
INSERT INTO pdev_migrations (migration_name) VALUES ('005_create_guest_tokens')
ON CONFLICT (migration_name) DO NOTHING;

COMMIT;
