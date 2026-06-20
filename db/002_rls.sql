-- Force RLS on every tenant-scoped table. FORCE means even the table owner
-- is subject to the policies (defense against accidental queries from app_owner).
-- The runtime role is NOBYPASSRLS, set in 001_init.sql.

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

-- The single source of truth for tenancy is the GUC `app.tenant_id`, set via
-- SET LOCAL inside the transaction. If it is unset, the policies match nothing.

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
ALTER TABLE tenants ENABLE ROW LEVEL SECURITY;
CREATE POLICY tenants_readable ON tenants FOR SELECT USING (true);

RESET ROLE;
