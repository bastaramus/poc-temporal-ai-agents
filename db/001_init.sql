-- Runs as the postgres superuser via bitnami initdb.
-- Creates roles, the poc database, and the schema. The runtime role MUST NOT
-- be the table owner and MUST NOT have BYPASSRLS.

CREATE ROLE app_owner   WITH LOGIN PASSWORD 'change-me-owner';
CREATE ROLE app_runtime WITH LOGIN PASSWORD 'change-me-runtime' NOBYPASSRLS;

-- Temporal and Keycloak each need their own DB; bitnami creates only the
-- one named in auth.database (poc). We're already running as superuser here.
CREATE DATABASE keycloak            OWNER postgres;
CREATE DATABASE temporal            OWNER postgres;
CREATE DATABASE temporal_visibility OWNER postgres;

-- The poc DB. Bitnami already created it with owner=app_owner via auth.username.
GRANT CONNECT ON DATABASE poc TO app_runtime;

\connect poc

CREATE EXTENSION IF NOT EXISTS pgcrypto;

SET ROLE app_owner;

CREATE TABLE tenants (
  id    UUID PRIMARY KEY,
  slug  TEXT NOT NULL UNIQUE,
  name  TEXT NOT NULL
);

CREATE TABLE users (
  sub               TEXT PRIMARY KEY,           -- Keycloak sub
  tenant_id         UUID NOT NULL REFERENCES tenants(id),
  preferred_username TEXT NOT NULL,
  email             TEXT NOT NULL
);
CREATE INDEX users_tenant_idx ON users(tenant_id);

CREATE TABLE documents (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   UUID NOT NULL,
  title       TEXT NOT NULL,
  content     TEXT NOT NULL,
  created_by  TEXT,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX documents_tenant_idx ON documents(tenant_id);

CREATE TABLE agent_runs (
  id          UUID PRIMARY KEY DEFAULT gen_random_uuid(),
  tenant_id   UUID NOT NULL,
  user_sub    TEXT NOT NULL,
  workflow_id TEXT,
  status      TEXT NOT NULL,
  result      JSONB,
  created_at  TIMESTAMPTZ NOT NULL DEFAULT now(),
  updated_at  TIMESTAMPTZ NOT NULL DEFAULT now()
);
CREATE INDEX agent_runs_tenant_idx ON agent_runs(tenant_id);

CREATE TABLE audit_log (
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
CREATE INDEX audit_log_tenant_idx ON audit_log(tenant_id);

-- Runtime role gets only DML on these tables, never ownership.
GRANT USAGE ON SCHEMA public TO app_runtime;
GRANT SELECT, INSERT, UPDATE        ON tenants, users, documents, agent_runs TO app_runtime;
GRANT SELECT, INSERT                ON audit_log                              TO app_runtime;
GRANT USAGE, SELECT ON ALL SEQUENCES IN SCHEMA public TO app_runtime;

RESET ROLE;
-- 002_rls.sql and 003_seed.sql are run automatically by bitnami initdb in
-- alphabetical order — they live in the same ConfigMap and don't need an \i.
