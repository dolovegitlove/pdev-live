-- PDev Live Database Schema
-- Migration: 001_create_tables
-- Version: 1.0.0

BEGIN;

-- Migration tracking table
CREATE TABLE IF NOT EXISTS pdev_migrations (
    id SERIAL PRIMARY KEY,
    migration_name VARCHAR(255) UNIQUE NOT NULL,
    applied_at TIMESTAMPTZ DEFAULT NOW()
);

-- Check if migration already applied
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pdev_migrations WHERE migration_name = '001_create_tables') THEN
        RAISE NOTICE 'Migration 001_create_tables already applied, skipping';
        RETURN;
    END IF;
END $$;

-- Sessions table
CREATE TABLE IF NOT EXISTS pdev_sessions (
    id UUID PRIMARY KEY DEFAULT gen_random_uuid(),
    server_origin VARCHAR(100),
    hostname VARCHAR(255),
    project_name VARCHAR(255) NOT NULL,
    project_path TEXT,
    cwd TEXT,
    command_type VARCHAR(100) NOT NULL,
    command_args TEXT,
    user_name VARCHAR(100),
    git_branch VARCHAR(255),
    git_commit VARCHAR(40),
    started_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),
    completed_at TIMESTAMP WITH TIME ZONE,
    session_status VARCHAR(50) DEFAULT 'active' CHECK (session_status IN ('active', 'paused', 'completed', 'archived', 'error')),
    deleted_at TIMESTAMP WITH TIME ZONE,
    metadata JSONB DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW()
);

-- Session steps table
CREATE TABLE IF NOT EXISTS pdev_session_steps (
    id SERIAL PRIMARY KEY,
    session_id UUID REFERENCES pdev_sessions(id) ON DELETE CASCADE,
    step_number INTEGER NOT NULL,
    step_type VARCHAR(50) NOT NULL,
    content TEXT NOT NULL,
    content_html TEXT,
    phase_number INTEGER,
    phase_name VARCHAR(255),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT NOW(),

    CONSTRAINT unique_session_step UNIQUE (session_id, step_number)
);

-- Performance indexes
CREATE INDEX IF NOT EXISTS idx_pdev_sessions_active
    ON pdev_sessions(session_status) WHERE session_status = 'active';

CREATE INDEX IF NOT EXISTS idx_pdev_sessions_project
    ON pdev_sessions(project_name);

CREATE INDEX IF NOT EXISTS idx_pdev_sessions_started
    ON pdev_sessions(started_at DESC);

CREATE INDEX IF NOT EXISTS idx_pdev_session_steps_session
    ON pdev_session_steps(session_id);

CREATE INDEX IF NOT EXISTS idx_pdev_session_steps_type
    ON pdev_session_steps(session_id, step_type);

-- JSONB index for metadata queries
CREATE INDEX IF NOT EXISTS idx_pdev_sessions_metadata
    ON pdev_sessions USING GIN (metadata);

-- Grant permissions to pdev_app user
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pdev_migrations TO pdev_app;
GRANT USAGE, SELECT ON SEQUENCE pdev_migrations_id_seq TO pdev_app;

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pdev_sessions TO pdev_app;
-- Note: pdev_sessions uses gen_random_uuid(), no sequence grant needed

GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pdev_session_steps TO pdev_app;
GRANT USAGE, SELECT ON SEQUENCE pdev_session_steps_id_seq TO pdev_app;

-- Record migration
INSERT INTO pdev_migrations (migration_name) VALUES ('001_create_tables')
ON CONFLICT (migration_name) DO NOTHING;

COMMIT;
