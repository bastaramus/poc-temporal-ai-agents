// Keycloak client used by internal-api-server.
//
// Two flows live here:
//   1. clientCredentialsLogin() — internal-api-server logs in as itself (its own
//      service account in Keycloak). The resulting access token is the subject
//      token for the exchange.
//   2. tokenExchange()         — RFC 8693 token-exchange call that narrows the
//      subject token: targets `worker-pod-client` as audience and adds claims
//      tenant_id, workflow_id, capabilities[].
//
// Both endpoints live at <issuer>/protocol/openid-connect/token.

const TOKEN_URL = process.env.KEYCLOAK_TOKEN_URL!;
const CLIENT_ID = process.env.INTERNAL_CLIENT_ID!;
const CLIENT_SECRET = process.env.INTERNAL_CLIENT_SECRET!;
const WORKER_AUDIENCE = process.env.WORKER_AUDIENCE ?? 'worker-pod-client';

export async function clientCredentialsLogin(): Promise<string> {
  const body = new URLSearchParams({
    grant_type: 'client_credentials',
    client_id: CLIENT_ID,
    client_secret: CLIENT_SECRET,
  });
  const res = await fetch(TOKEN_URL, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body,
  });
  if (!res.ok) {
    throw new Error(`client_credentials failed: ${res.status} ${await res.text()}`);
  }
  const json = (await res.json()) as { access_token: string };
  return json.access_token;
}

export async function tokenExchange(args: {
  subjectToken: string;
  tenant_id: string;
  workflow_id: string;
  capabilities: string[];
}): Promise<{ access_token: string; expires_in: number }> {
  // Standard fields from RFC 8693. Keycloak uses `audience` to set the target
  // client. Custom claims have to be added via a Keycloak protocol-mapper or a
  // `requested_token_type` / `claims` parameter; for the PoC we do a second
  // mapping using the `audience` param plus a JSON `claims` parameter that the
  // mapper picks up.
  const body = new URLSearchParams({
    grant_type: 'urn:ietf:params:oauth:grant-type:token-exchange',
    client_id: CLIENT_ID,
    client_secret: CLIENT_SECRET,
    subject_token: args.subjectToken,
    subject_token_type: 'urn:ietf:params:oauth:token-type:access_token',
    requested_token_type: 'urn:ietf:params:oauth:token-type:access_token',
    audience: WORKER_AUDIENCE,
    // Keycloak's hardcoded claim-mapper picks up these extra params and adds
    // them as token claims when configured. For the PoC the mapper is wired in
    // realm-export.json (see comment in that file). Worst case in the PoC if
    // the mapper isn't picked up automatically, the worker's calls still fail
    // closed because tenant_id will be missing from the narrowed JWT.
    'claim_token_format': 'urn:ietf:params:oauth:token-type:jwt',
    'tenant_id': args.tenant_id,
    'workflow_id': args.workflow_id,
    'capabilities': args.capabilities.join(','),
  });
  const res = await fetch(TOKEN_URL, {
    method: 'POST',
    headers: { 'content-type': 'application/x-www-form-urlencoded' },
    body,
  });
  if (!res.ok) {
    throw new Error(`token-exchange failed: ${res.status} ${await res.text()}`);
  }
  return (await res.json()) as { access_token: string; expires_in: number };
}
