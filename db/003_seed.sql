\connect poc
SET ROLE app_owner;

INSERT INTO tenants (id, slug, name) VALUES
  ('11111111-1111-1111-1111-111111111111', 'tenant-a', 'Tenant A'),
  ('22222222-2222-2222-2222-222222222222', 'tenant-b', 'Tenant B');

-- The user `sub` values match the IDs in keycloak/realm-export.json.
-- We bypass RLS for the seed by using the owner role and disabling FORCE briefly
-- via SET row_security = off (only superuser/owner can do this).
SET row_security = off;

INSERT INTO users (sub, tenant_id, preferred_username, email) VALUES
  ('alice-sub-0001', '11111111-1111-1111-1111-111111111111', 'alice', 'alice@example.com'),
  ('bob-sub-0002',   '22222222-2222-2222-2222-222222222222', 'bob',   'bob@example.com');

SET row_security = on;
RESET ROLE;
