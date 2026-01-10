-- PDev Live Database Schema
-- Migration: 002_add_missing_objects
-- Version: 1.0.1
-- Fixes: Missing tables/views required by server.js

BEGIN;

-- Check if migration already applied
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pdev_migrations WHERE migration_name = '002_add_missing_objects') THEN
        RAISE NOTICE 'Migration 002_add_missing_objects already applied, skipping';
        RETURN;
    END IF;
END $$;

-- Fix table name mismatch: server.js queries pdev_steps but migration created pdev_session_steps
-- Create pdev_steps as alias/view to pdev_session_steps
CREATE OR REPLACE VIEW pdev_steps AS
SELECT
    id,
    session_id,
    step_number,
    step_type,
    content,
    content_html,
    phase_number,
    phase_name,
    created_at
FROM pdev_session_steps;

-- Create project_manifests table
CREATE TABLE IF NOT EXISTS project_manifests (
    id SERIAL PRIMARY KEY,
    server_origin VARCHAR(100) NOT NULL,
    project_name VARCHAR(255) NOT NULL,
    project_path TEXT,
    git_remote VARCHAR(500),
    git_branch VARCHAR(255),
    last_session_id UUID REFERENCES pdev_sessions(id) ON DELETE SET NULL,
    document_types TEXT[], -- Array of document types produced (IDEATION, SPEC, SOP, etc.)
    metadata JSONB DEFAULT '{}'::jsonb,
    created_at TIMESTAMPTZ DEFAULT NOW(),
    updated_at TIMESTAMPTZ DEFAULT NOW(),

    CONSTRAINT unique_project UNIQUE (server_origin, project_name)
);

-- Performance indexes for project_manifests
CREATE INDEX IF NOT EXISTS idx_project_manifests_server
    ON project_manifests(server_origin);

CREATE INDEX IF NOT EXISTS idx_project_manifests_project
    ON project_manifests(server_origin, project_name);

CREATE INDEX IF NOT EXISTS idx_project_manifests_metadata
    ON project_manifests USING GIN (metadata);

-- Create v_active_sessions view
CREATE OR REPLACE VIEW v_active_sessions AS
SELECT
    s.id,
    s.server_origin,
    s.hostname,
    s.project_name,
    s.project_path,
    s.cwd,
    s.command_type,
    s.command_args,
    s.user_name,
    s.git_branch,
    s.git_commit,
    s.started_at,
    s.session_status,
    s.metadata,
    COUNT(st.id) as step_count,
    MAX(st.created_at) as last_step_at
FROM pdev_sessions s
LEFT JOIN pdev_session_steps st ON s.id = st.session_id
WHERE s.session_status = 'active'
  AND s.deleted_at IS NULL
GROUP BY s.id
ORDER BY s.started_at DESC;

-- Create v_session_history view
CREATE OR REPLACE VIEW v_session_history AS
SELECT
    s.id,
    s.server_origin,
    s.hostname,
    s.project_name,
    s.project_path,
    s.cwd,
    s.command_type,
    s.command_args,
    s.user_name,
    s.git_branch,
    s.git_commit,
    s.started_at,
    s.completed_at,
    s.session_status,
    s.metadata,
    COUNT(st.id) as step_count,
    MAX(st.created_at) as last_step_at,
    EXTRACT(EPOCH FROM (COALESCE(s.completed_at, NOW()) - s.started_at)) as duration_seconds
FROM pdev_sessions s
LEFT JOIN pdev_session_steps st ON s.id = st.session_id
WHERE s.session_status IN ('completed', 'archived')
  AND s.deleted_at IS NULL
GROUP BY s.id
ORDER BY s.started_at DESC;

-- Grant permissions to pdev_app user
-- Updatable view - needs full DML
GRANT SELECT, INSERT, UPDATE, DELETE ON pdev_steps TO pdev_app;

-- Read-only views - SELECT only
GRANT SELECT ON v_active_sessions TO pdev_app;
GRANT SELECT ON v_session_history TO pdev_app;

-- Project manifests table
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE project_manifests TO pdev_app;
GRANT USAGE, SELECT ON SEQUENCE project_manifests_id_seq TO pdev_app;

-- Record migration
INSERT INTO pdev_migrations (migration_name) VALUES ('002_add_missing_objects')
ON CONFLICT (migration_name) DO NOTHING;

COMMIT;
