-- Seed runs as the `postgres` superuser (which has BYPASSRLS).
-- We don't SET ROLE app_owner here — app_owner is subject to FORCE RLS, and
-- the FORCE bit can't be turned off per-statement.
\connect poc

INSERT INTO tenants (id, slug, name) VALUES
  ('11111111-1111-1111-1111-111111111111', 'tenant-a', 'Tenant A'),
  ('22222222-2222-2222-2222-222222222222', 'tenant-b', 'Tenant B')
ON CONFLICT (id) DO NOTHING;

-- The user `sub` values match the IDs in keycloak/realm-export.json.
INSERT INTO users (sub, tenant_id, preferred_username, email) VALUES
  ('alice-sub-0001', '11111111-1111-1111-1111-111111111111', 'alice', 'alice@example.com'),
  ('bob-sub-0002',   '22222222-2222-2222-2222-222222222222', 'bob',   'bob@example.com')
ON CONFLICT (sub) DO NOTHING;
