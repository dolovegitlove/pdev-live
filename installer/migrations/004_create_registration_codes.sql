-- Migration: 004_create_registration_codes
-- Purpose: Add time-limited registration codes for secure automated installations

-- Create registration_codes table
CREATE TABLE IF NOT EXISTS registration_codes (
  id SERIAL PRIMARY KEY,
  code VARCHAR(32) NOT NULL UNIQUE,
  created_at TIMESTAMP DEFAULT NOW(),
  expires_at TIMESTAMP NOT NULL,
  created_by VARCHAR(100),
  created_ip VARCHAR(45),
  consumed_at TIMESTAMP,
  consumed_by VARCHAR(50),
  consumed_ip VARCHAR(45)
);

-- Index for fast code lookups (only active codes)
CREATE INDEX IF NOT EXISTS idx_registration_codes_code ON registration_codes(code) WHERE consumed_at IS NULL AND expires_at > NOW();

-- Index for cleanup (find expired codes)
CREATE INDEX IF NOT EXISTS idx_registration_codes_expires ON registration_codes(expires_at) WHERE consumed_at IS NULL;

-- Record migration
INSERT INTO pdev_migrations (migration_name) VALUES ('004_create_registration_codes')
ON CONFLICT (migration_name) DO NOTHING;
