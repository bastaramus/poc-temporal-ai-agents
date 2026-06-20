-- Force RLS on every tenant-scoped table. FORCE means even the table owner
-- is subject to the policies (defense against accidental queries from app_owner).
-- The runtime role is NOBYPASSRLS, set in 001_init.sql.
-- Idempotent: ALTER TABLE … ENABLE/FORCE RLS is no-op on second run; policies
-- are wrapped in DROP IF EXISTS so re-runs replace them cleanly.

\connect poc
SET ROLE app_owner;

ALTER TABLE documents  ENABLE ROW LEVEL SECURITY;
ALTER TABLE documents  FORCE  ROW LEVEL SECURITY;
ALTER TABLE agent_runs ENABLE ROW LEVEL SECURITY;
ALTER TABLE agent_runs FORCE  ROW LEVEL SECURITY;
ALTER TABLE audit_log  ENABLE ROW LEVEL SECURITY;
ALTER TABLE audit_log  FORCE  ROW LEVEL SECURITY;
ALTER TABLE users      ENABLE ROW LEVEL SECURITY;
ALTER TABLE users      FORCE  ROW LEVEL SECURITY;
ALTER TABLE tenants    ENABLE ROW LEVEL SECURITY;

DROP POLICY IF EXISTS tenant_isolation_documents  ON documents;
DROP POLICY IF EXISTS tenant_isolation_agent_runs ON agent_runs;
DROP POLICY IF EXISTS tenant_isolation_audit_log  ON audit_log;
DROP POLICY IF EXISTS tenant_isolation_users      ON users;
DROP POLICY IF EXISTS tenants_readable            ON tenants;

CREATE POLICY tenant_isolation_documents ON documents
  USING      (tenant_id = current_setting('app.tenant_id', true)::uuid)
  WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::uuid);

CREATE POLICY tenant_isolation_agent_runs ON agent_runs
  USING      (tenant_id = current_setting('app.tenant_id', true)::uuid)
  WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::uuid);

CREATE POLICY tenant_isolation_audit_log ON audit_log
  USING      (tenant_id = current_setting('app.tenant_id', true)::uuid)
  WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::uuid);

CREATE POLICY tenant_isolation_users ON users
  USING      (tenant_id = current_setting('app.tenant_id', true)::uuid)
  WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::uuid);

-- tenants table is global metadata; runtime role is read-only on it.
CREATE POLICY tenants_readable ON tenants FOR SELECT USING (true);

RESET ROLE;
