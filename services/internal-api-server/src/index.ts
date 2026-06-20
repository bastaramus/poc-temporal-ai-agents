import Fastify from 'fastify';
import { Connection, WorkflowClient } from '@temporalio/client';
import { createRemoteJWKSet, jwtVerify } from 'jose';

import { verifyServiceAccountToken } from './k8s.js';
import { clientCredentialsLogin, tokenExchange } from './keycloak.js';
import { withTenantTx, audit } from './db.js';

const ISSUER = process.env.KEYCLOAK_ISSUER!;
const JWKS_URL = process.env.KEYCLOAK_JWKS_URL!;
const WORKER_AUDIENCE = process.env.WORKER_AUDIENCE ?? 'worker-pod-client';
const TEMPORAL_HOST = process.env.TEMPORAL_HOST ?? 'localhost:7233';
const TEMPORAL_NAMESPACE = process.env.TEMPORAL_NAMESPACE ?? 'default';
const PORT = parseInt(process.env.PORT ?? '8080', 10);

const jwks = createRemoteJWKSet(new URL(JWKS_URL));

async function verifyNarrowedJwt(authz: string | undefined) {
  if (!authz?.startsWith('Bearer ')) throw new Error('missing bearer');
  const token = authz.slice('Bearer '.length);
  const { payload } = await jwtVerify(token, jwks, { issuer: ISSUER });
  // Critical audience check: tool endpoints accept ONLY narrowed tokens.
  // A user JWT (audience=public-api-client) replayed here must fail.
  const aud = payload.aud;
  const audMatches = Array.isArray(aud) ? aud.includes(WORKER_AUDIENCE) : aud === WORKER_AUDIENCE;
  if (!audMatches) throw new Error(`bad audience: ${JSON.stringify(aud)}`);

  const tenant_id = payload.tenant_id;
  if (typeof tenant_id !== 'string') throw new Error('tenant_id missing');
  const workflow_id = typeof payload.workflow_id === 'string' ? payload.workflow_id : null;
  const capabilities =
    typeof payload.capabilities === 'string'
      ? payload.capabilities.split(',').map((s) => s.trim())
      : Array.isArray(payload.capabilities)
        ? (payload.capabilities as string[])
        : [];
  return { tenant_id, workflow_id, capabilities, sub: String(payload.sub ?? 'pod') };
}

async function main() {
  const conn = await Connection.connect({ address: TEMPORAL_HOST });
  const app = Fastify({ logger: true });

  // ────────────────────────── /bind-identity ──────────────────────────
  // Pod sends its projected SA token + the workflow_id it claims to be working
  // on. We verify the SA token via TokenReview, then ask Temporal what tenant
  // that workflow actually belongs to, then ask Keycloak to mint a narrowed
  // JWT for that tenant.
  app.post('/bind-identity', async (req, reply) => {
    const authz = req.headers.authorization;
    if (!authz?.startsWith('Bearer ')) {
      return reply.code(401).send({ error: 'missing_sa_token' });
    }
    const saToken = authz.slice('Bearer '.length);

    let saUser: string;
    try {
      const r = await verifyServiceAccountToken(saToken);
      saUser = r.username;
    } catch (e) {
      req.log.warn({ err: String(e) }, 'SA TokenReview failed');
      return reply.code(401).send({ error: 'invalid_sa_token' });
    }

    const body = (req.body ?? {}) as { workflow_id?: string };
    if (!body.workflow_id) {
      return reply.code(400).send({ error: 'workflow_id_required' });
    }

    // Resolve trusted tenant_id from Temporal workflow memo. Memo was set by
    // public-api-server when it called StartWorkflow, using the JWT-verified
    // tenant_id. The pod cannot influence this value.
    //
    // Single shared Temporal namespace: there is no per-tenant ns, the
    // tenant boundary lives in (a) JWT-on-public-api, (b) memo on the
    // workflow, (c) Postgres RLS. Adding ns-per-tenant would buy a fourth
    // boundary at the cost of operator-driven provisioning, which §7 of
    // SUMBISSION.md explicitly refuses.
    const wfClient = new WorkflowClient({ connection: conn, namespace: TEMPORAL_NAMESPACE });
    let trustedTenantId: string;
    try {
      const handle = wfClient.getHandle(body.workflow_id);
      const desc = await handle.describe();
      const memo = desc.memo as Record<string, unknown> | undefined;
      const memoTenant = memo?.tenant_id;
      if (typeof memoTenant !== 'string') {
        throw new Error('tenant_id memo missing on workflow');
      }
      trustedTenantId = memoTenant;
    } catch (e) {
      req.log.warn({ err: String(e), wf: body.workflow_id }, 'temporal describe failed');
      return reply.code(403).send({ error: 'workflow_not_resolvable' });
    }

    // Mint the narrowed token via token-exchange.
    let narrowed: { access_token: string; expires_in: number };
    try {
      const subjectToken = await clientCredentialsLogin();
      narrowed = await tokenExchange({
        subjectToken,
        tenant_id: trustedTenantId,
        workflow_id: body.workflow_id,
        capabilities: ['tool:read-doc', 'tool:write-doc'],
      });
    } catch (e) {
      req.log.error({ err: String(e) }, 'token-exchange failed');
      return reply.code(500).send({ error: 'token_exchange_failed' });
    }

    req.log.info(
      { sa: saUser, tenant_id: trustedTenantId, workflow_id: body.workflow_id },
      'bound identity'
    );
    return reply.send({
      access_token: narrowed.access_token,
      expires_in: narrowed.expires_in,
      tenant_id: trustedTenantId,
    });
  });

  // ────────────────────────── /tools/write-doc ──────────────────────────
  app.post('/tools/write-doc', async (req, reply) => {
    let claims: { tenant_id: string; capabilities: string[]; sub: string };
    try {
      claims = await verifyNarrowedJwt(req.headers.authorization);
    } catch (e) {
      req.log.warn({ err: String(e) }, 'narrowed JWT verify failed');
      return reply.code(401).send({ error: 'invalid_token' });
    }
    if (!claims.capabilities.includes('tool:write-doc')) {
      return reply.code(403).send({ error: 'missing_capability' });
    }

    const body = (req.body ?? {}) as Record<string, unknown>;
    if ('tenant_id' in body) {
      req.log.warn({ body_tenant: body.tenant_id }, 'rejecting body tenant_id');
      return reply.code(400).send({ error: 'tenant_id_in_body_forbidden' });
    }
    const title = typeof body.title === 'string' ? body.title : null;
    const content = typeof body.content === 'string' ? body.content : null;
    if (!title || !content) {
      return reply.code(400).send({ error: 'title_and_content_required' });
    }

    const result = await withTenantTx(claims.tenant_id, async (client) => {
      const ins = await client.query<{ id: string }>(
        `INSERT INTO documents (tenant_id, title, content, created_by)
         VALUES ($1::uuid, $2, $3, $4) RETURNING id`,
        [claims.tenant_id, title, content, claims.sub]
      );
      const docId = ins.rows[0].id;
      await audit(client, {
        tenant_id: claims.tenant_id,
        actor: claims.sub,
        action: 'write-doc',
        resource_type: 'document',
        resource_id: docId,
        decision: 'allow',
      });
      return { document_id: docId };
    });

    return reply.send(result);
  });

  // ────────────────────────── /tools/read-doc ───────────────────────────
  app.post('/tools/read-doc', async (req, reply) => {
    let claims: { tenant_id: string; capabilities: string[]; sub: string };
    try {
      claims = await verifyNarrowedJwt(req.headers.authorization);
    } catch (e) {
      req.log.warn({ err: String(e) }, 'narrowed JWT verify failed');
      return reply.code(401).send({ error: 'invalid_token' });
    }
    if (!claims.capabilities.includes('tool:read-doc')) {
      return reply.code(403).send({ error: 'missing_capability' });
    }

    const body = (req.body ?? {}) as Record<string, unknown>;
    if ('tenant_id' in body) {
      return reply.code(400).send({ error: 'tenant_id_in_body_forbidden' });
    }
    const docId = typeof body.document_id === 'string' ? body.document_id : null;
    if (!docId) return reply.code(400).send({ error: 'document_id_required' });

    const result = await withTenantTx(claims.tenant_id, async (client) => {
      const r = await client.query<{ id: string; title: string; content: string }>(
        `SELECT id, title, content FROM documents WHERE id = $1`,
        [docId]
      );
      // RLS: if the doc belongs to a different tenant, this returns 0 rows
      // even though the WHERE clause didn't filter by tenant.
      if (r.rows.length === 0) {
        await audit(client, {
          tenant_id: claims.tenant_id,
          actor: claims.sub,
          action: 'read-doc',
          resource_type: 'document',
          resource_id: docId,
          decision: 'deny',
          reason: 'not_found_under_tenant',
        });
        return { found: false };
      }
      await audit(client, {
        tenant_id: claims.tenant_id,
        actor: claims.sub,
        action: 'read-doc',
        resource_type: 'document',
        resource_id: docId,
        decision: 'allow',
      });
      return { found: true, document: r.rows[0] };
    });

    return reply.send(result);
  });

  app.get('/healthz', async () => ({ ok: true }));

  await app.listen({ host: '0.0.0.0', port: PORT });
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
