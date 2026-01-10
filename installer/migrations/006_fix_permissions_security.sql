-- Migration: 006_fix_permissions_security
-- Purpose: Replace ALL PRIVILEGES with least-privilege permissions (SELECT, INSERT, UPDATE, DELETE)
-- Security: Remove DDL permissions (ALTER, DROP, TRUNCATE, REFERENCES, TRIGGER)

BEGIN;

-- Check if migration already applied
DO $$
BEGIN
    IF EXISTS (SELECT 1 FROM pdev_migrations WHERE migration_name = '006_fix_permissions_security') THEN
        RAISE NOTICE 'Migration 006_fix_permissions_security already applied, skipping';
        RETURN;
    END IF;
END $$;

-- Revoke ALL PRIVILEGES (includes DDL permissions we don't want)
REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM pdev_app;
REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public FROM pdev_app;

-- Grant restricted DML permissions on tables (from migration 001)
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pdev_migrations TO pdev_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pdev_sessions TO pdev_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE pdev_session_steps TO pdev_app;

-- Grant sequence permissions (from migration 001)
GRANT USAGE, SELECT ON SEQUENCE pdev_migrations_id_seq TO pdev_app;
GRANT USAGE, SELECT ON SEQUENCE pdev_session_steps_id_seq TO pdev_app;

-- Grant permissions on views and tables (from migration 002)
GRANT SELECT, INSERT, UPDATE, DELETE ON pdev_steps TO pdev_app;
GRANT SELECT ON v_active_sessions TO pdev_app;
GRANT SELECT ON v_session_history TO pdev_app;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE project_manifests TO pdev_app;
GRANT USAGE, SELECT ON SEQUENCE project_manifests_id_seq TO pdev_app;

-- Grant permissions on server_tokens (from migration 003)
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE server_tokens TO pdev_app;
GRANT USAGE, SELECT ON SEQUENCE server_tokens_id_seq TO pdev_app;

-- Grant permissions on registration_codes (from migration 004)
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE registration_codes TO pdev_app;
GRANT USAGE, SELECT ON SEQUENCE registration_codes_id_seq TO pdev_app;

-- Grant permissions on guest_tokens (from migration 005)
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE guest_tokens TO pdev_app;
GRANT USAGE, SELECT ON SEQUENCE guest_tokens_id_seq TO pdev_app;

-- Record migration
INSERT INTO pdev_migrations (migration_name) VALUES ('006_fix_permissions_security')
ON CONFLICT (migration_name) DO NOTHING;

COMMIT;
