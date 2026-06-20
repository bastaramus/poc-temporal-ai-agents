-- Idempotent schema bootstrap for the poc DB.
-- Runs as the postgres superuser via bitnami initdb on a fresh PVC, AND can be
-- safely re-run by hand against an existing PVC where initdb didn't fire.
-- Every CREATE is guarded so re-runs produce no diff.

-- Roles ───────────────────────────────────────────────────────────────────
DO $$ BEGIN
  CREATE ROLE app_owner   WITH LOGIN PASSWORD 'change-me-owner';
EXCEPTION WHEN duplicate_object THEN
  ALTER ROLE app_owner   WITH LOGIN PASSWORD 'change-me-owner';
END $$;

DO $$ BEGIN
  CREATE ROLE app_runtime WITH LOGIN PASSWORD 'change-me-runtime' NOBYPASSRLS;
EXCEPTION WHEN duplicate_object THEN
  ALTER ROLE app_runtime WITH LOGIN PASSWORD 'change-me-runtime' NOBYPASSRLS;
END $$;

-- Side databases (Temporal + Keycloak each need their own) ────────────────
SELECT 'CREATE DATABASE keycloak             OWNER postgres'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'keycloak') \gexec
SELECT 'CREATE DATABASE temporal             OWNER postgres'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'temporal') \gexec
SELECT 'CREATE DATABASE temporal_visibility  OWNER postgres'
WHERE NOT EXISTS (SELECT 1 FROM pg_database WHERE datname = 'temporal_visibility') \gexec

-- The poc DB. Bitnami already created it with owner=app_owner via auth.username.
GRANT CONNECT ON DATABASE poc TO app_runtime;

\connect poc

CREATE EXTENSION IF NOT EXISTS pgcrypto;

SET ROLE app_owner;

CREATE TABLE IF NOT EXISTS tenants (
  id    UUID PRIMARY KEY,
  slug  TEXT NOT NULL UNIQUE,
  name  TEXT NOT NULL
);

CREATE TABLE IF NOT EXISTS users (
  sub                TEXT PRIMARY KEY,           -- Keycloak sub
  tenant_id          UUID NOT NULL REFERENCES tenants(id),
  preferred_username TEXT NOT NULL,
  email              TEXT NOT NULL
);
CREATE INDEX IF NOT EXISTS users_tenant_idx ON users(tenant_id);

CREATE TABLE IF NOT EXISTS documents (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   UUID NOT NULL,
  title       TEXT NOT NULL,
  content     TEXT NOT NULL,
  created_by  TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS documents_tenant_idx ON documents(tenant_id);

CREATE TABLE IF NOT EXISTS agent_runs (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   UUID NOT NULL,
  user_sub    TEXT NOT NULL,
  workflow_id TEXT,
  status      TEXT NOT NULL,
  result      JSONB,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS agent_runs_tenant_idx ON agent_runs(tenant_id);

CREATE TABLE IF NOT EXISTS audit_log (
  id            UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id     UUID NOT NULL,
  actor         TEXT NOT NULL,
  action        TEXT NOT NULL,
  resource_type TEXT NOT NULL,
  resource_id   TEXT,
  decision      TEXT NOT NULL,
  reason        TEXT,
  created_at    TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS audit_log_tenant_idx ON audit_log(tenant_id);

-- Runtime role gets only DML on these tables, never ownership.
GRANT USAGE ON SCHEMA public TO app_runtime;
GRANT SELECT, INSERT, UPDATE  ON tenants, users, documents, agent_runs TO app_runtime;
GRANT SELECT, INSERT          ON audit_log                              TO app_runtime;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO app_runtime;

RESET ROLE;
-- 002_rls.sql and 003_seed.sql run after this (alphabetical order in the ConfigMap).
