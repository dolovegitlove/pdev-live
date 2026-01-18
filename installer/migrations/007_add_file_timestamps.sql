-- PDev Live Database Schema
-- Migration: 007_add_file_timestamps
-- Version: 1.0.0
-- Purpose: Add file system timestamp tracking (file created, file modified)

BEGIN;

-- Check if migration already applied
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pdev_migrations WHERE migration_name = '007_add_file_timestamps') THEN
        RAISE NOTICE 'Migration 007_add_file_timestamps already applied, skipping';
        RETURN;
    END IF;
END $$;

-- Add file timestamp columns to physical table
ALTER TABLE pdev_session_steps
ADD COLUMN IF NOT EXISTS file_created_at TIMESTAMPTZ,
ADD COLUMN IF NOT EXISTS file_modified_at TIMESTAMPTZ;

-- Update view to include new columns
CREATE OR REPLACE VIEW pdev_steps AS
SELECT
    id,
    session_id,
    step_number,
    step_type,
    content,
    content_html,
    content_markdown,
    content_plain,
    sub_phase,
    command_text,
    exit_code,
    output_byte_size,
    document_name,
    phase_number,
    phase_name,
    created_at,
    file_created_at,
    file_modified_at
FROM pdev_session_steps;

-- Create index for file modification time queries
CREATE INDEX IF NOT EXISTS idx_pdev_session_steps_file_modified
    ON pdev_session_steps(file_modified_at DESC)
    WHERE file_modified_at IS NOT NULL;

-- Grant permissions (view permissions already granted in previous migrations)
GRANT SELECT, INSERT, UPDATE, DELETE ON pdev_steps TO pdev_app;

-- Record migration
INSERT INTO pdev_migrations (migration_name) VALUES ('007_add_file_timestamps')
ON CONFLICT (migration_name) DO NOTHING;

COMMIT;
