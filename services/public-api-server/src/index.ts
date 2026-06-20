import Fastify from 'fastify';
import { Connection, Client } from '@temporalio/client';
import { createRemoteJWKSet, jwtVerify } from 'jose';

const ISSUER = process.env.KEYCLOAK_ISSUER!;
const JWKS_URL = process.env.KEYCLOAK_JWKS_URL!;
const AUDIENCE = process.env.EXPECTED_AUDIENCE ?? 'public-api-client';
const TEMPORAL_HOST = process.env.TEMPORAL_HOST ?? 'localhost:7233';
const PORT = parseInt(process.env.PORT ?? '8080', 10);

const TEMPORAL_NAMESPACE = process.env.TEMPORAL_NAMESPACE ?? 'default';
const TASK_QUEUE = process.env.TASK_QUEUE ?? 'agent-tasks';
const KNOWN_TENANTS = new Set([
  '11111111-1111-1111-1111-111111111111',
  '22222222-2222-2222-2222-222222222222',
]);

const jwks = createRemoteJWKSet(new URL(JWKS_URL));

async function verifyUserJwt(authz: string | undefined) {
  if (!authz?.startsWith('Bearer ')) throw new Error('missing bearer');
  const token = authz.slice('Bearer '.length);
  const { payload } = await jwtVerify(token, jwks, { issuer: ISSUER });
  if (payload.azp !== AUDIENCE && payload.aud !== AUDIENCE) {
    throw new Error(`bad audience: azp=${payload.azp} aud=${JSON.stringify(payload.aud)}`);
  }
  const tenant_id = payload.tenant_id;
  if (typeof tenant_id !== 'string') throw new Error('tenant_id missing in JWT');
  // Prefer sub (stable identifier), fall back to preferred_username for
  // public-client password-grant flows where Keycloak may omit sub.
  const sub =
    typeof payload.sub === 'string'
      ? payload.sub
      : typeof payload.preferred_username === 'string'
        ? (payload.preferred_username as string)
        : undefined;
  if (!sub) throw new Error('no usable subject claim (sub or preferred_username)');
  return { tenant_id, sub };
}

async function main() {
  const conn = await Connection.connect({ address: TEMPORAL_HOST });
  const app = Fastify({ logger: true });

  app.post('/start-check', async (req, reply) => {
    let claims: { tenant_id: string; sub: string };
    try {
      claims = await verifyUserJwt(req.headers.authorization);
    } catch (e) {
      req.log.warn({ err: String(e) }, 'jwt verify failed');
      return reply.code(401).send({ error: 'invalid_token' });
    }

    if (!KNOWN_TENANTS.has(claims.tenant_id)) {
      return reply.code(403).send({ error: 'unknown_tenant' });
    }

    const body = (req.body ?? {}) as Record<string, unknown>;
    if ('tenant_id' in body) {
      req.log.warn(
        { jwt_tenant: claims.tenant_id, body_tenant: body.tenant_id },
        'ignoring body tenant_id (would be a tenant-confusion attempt)'
      );
    }

    const mode = body.mode === 'read' ? 'read' : 'write';
    const input = {
      tenant_id: claims.tenant_id,
      user_sub: claims.sub,
      mode,
      title: typeof body.title === 'string' ? body.title : undefined,
      content: typeof body.content === 'string' ? body.content : undefined,
      document_id: typeof body.document_id === 'string' ? body.document_id : undefined,
    };

    const client = new Client({ connection: conn, namespace: TEMPORAL_NAMESPACE });
    const handle = await client.workflow.start('StartCheckWorkflow', {
      args: [input],
      taskQueue: TASK_QUEUE,
      workflowId: `check-${claims.sub}-${Date.now()}`,
      // SECURITY-CRITICAL: tenant_id is written to Temporal memo. The
      // internal-api-server uses memo.tenant_id (NOT a value from the worker
      // pod) to decide what tenant the narrowed JWT will be scoped to.
      // This is the only thing that ties a workflow to its tenant — there is
      // no per-tenant Temporal namespace.
      memo: {
        tenant_id: claims.tenant_id,
        user_sub: claims.sub,
      },
    });

    const result = await handle.result();
    return reply.send({
      workflow_id: handle.workflowId,
      run_id: handle.firstExecutionRunId,
      status: 'completed',
      result,
    });
  });

  app.get('/healthz', async () => ({ ok: true }));

  await app.listen({ host: '0.0.0.0', port: PORT });
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
