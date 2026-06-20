// Postgres helper that enforces the SET LOCAL contract:
// every transaction MUST start with SET LOCAL app.tenant_id = <verified tenant>,
// every tool call MUST write an audit_log row before COMMIT.

import pg from 'pg';

export const pool = new pg.Pool({
  host: process.env.PG_HOST,
  port: parseInt(process.env.PG_PORT ?? '5432', 10),
  database: process.env.PG_DATABASE,
  user: process.env.PG_USER,
  password: process.env.PG_PASSWORD,
  max: 10,
});

export async function withTenantTx<T>(
  tenant_id: string,
  fn: (client: pg.PoolClient) => Promise<T>
): Promise<T> {
  const client = await pool.connect();
  try {
    await client.query('BEGIN');
    // set_config with is_local=true is equivalent to SET LOCAL but takes a
    // parameter — that lets us pass the verified tenant_id without string
    // interpolation. tenant_id is a uuid so it's already validated upstream,
    // but parameterizing is the right pattern.
    await client.query("SELECT set_config('app.tenant_id', $1, true)", [tenant_id]);
    const result = await fn(client);
    await client.query('COMMIT');
    return result;
  } catch (e) {
    await client.query('ROLLBACK').catch(() => undefined);
    throw e;
  } finally {
    client.release();
  }
}

export async function audit(
  client: pg.PoolClient,
  row: {
    tenant_id: string;
    actor: string;
    action: string;
    resource_type: string;
    resource_id: string | null;
    decision: 'allow' | 'deny';
    reason?: string;
  }
): Promise<void> {
  await client.query(
    `INSERT INTO audit_log
     (tenant_id, actor, action, resource_type, resource_id, decision, reason)
     VALUES ($1, $2, $3, $4, $5, $6, $7)`,
    [
      row.tenant_id,
      row.actor,
      row.action,
      row.resource_type,
      row.resource_id,
      row.decision,
      row.reason ?? null,
    ]
  );
}
