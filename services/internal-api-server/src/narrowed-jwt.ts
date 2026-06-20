// Narrowed-JWT minting + verification.
//
// internal-api-server is BOTH the issuer (mint at /bind-identity) and the
// verifier (check at /tools/*). Same HS256 secret, never leaves this process.
// The token is short-lived (default 15 min), tenant-scoped, capability-scoped,
// and tied to a specific workflow_id.
//
// Production path: swap mint/verify for a Keycloak token-exchange v2 +
// client-policies bundle. The token shape stays identical, so the call sites
// don't change.

import { SignJWT } from 'jose';

const WORKER_AUDIENCE = process.env.WORKER_AUDIENCE ?? 'worker-pod-client';
const NARROWED_TTL_SECONDS = parseInt(process.env.NARROWED_TTL_SECONDS ?? '900', 10);
const NARROWED_ISSUER = process.env.NARROWED_ISSUER ?? 'internal-api-server';
const NARROWED_SECRET = new TextEncoder().encode(
  process.env.NARROWED_SIGNING_SECRET ?? 'dev-only-change-me-in-prod'
);

export async function mintNarrowedJwt(args: {
  tenant_id: string;
  workflow_id: string;
  capabilities: string[];
  sub?: string;
}): Promise<{ access_token: string; expires_in: number }> {
  const now = Math.floor(Date.now() / 1000);
  const exp = now + NARROWED_TTL_SECONDS;
  const token = await new SignJWT({
    tenant_id: args.tenant_id,
    workflow_id: args.workflow_id,
    capabilities: args.capabilities,
  })
    .setProtectedHeader({ alg: 'HS256', typ: 'JWT' })
    .setIssuer(NARROWED_ISSUER)
    .setAudience(WORKER_AUDIENCE)
    .setSubject(args.sub ?? `pod:${args.workflow_id}`)
    .setIssuedAt(now)
    .setExpirationTime(exp)
    .setJti(`${args.workflow_id}-${now}`)
    .sign(NARROWED_SECRET);
  return { access_token: token, expires_in: NARROWED_TTL_SECONDS };
}

export const NARROWED_VERIFY_SECRET = NARROWED_SECRET;
export const NARROWED_EXPECTED_ISSUER = NARROWED_ISSUER;
