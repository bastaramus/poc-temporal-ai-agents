import { NativeConnection, Worker } from '@temporalio/worker';
import * as activities from './activities.js';

const TEMPORAL_HOST = process.env.TEMPORAL_HOST ?? 'localhost:7233';
const TEMPORAL_NAMESPACE = process.env.TEMPORAL_NAMESPACE ?? 'default';
const TASK_QUEUE = process.env.TASK_QUEUE ?? 'agent-tasks';

async function main() {
  const conn = await NativeConnection.connect({ address: TEMPORAL_HOST });

  // Single shared queue across all tenants. Tenant scoping happens at the
  // BindIdentity → narrowed JWT → RLS layer, not at the workflow router.
  const worker = await Worker.create({
    connection: conn,
    namespace: TEMPORAL_NAMESPACE,
    taskQueue: TASK_QUEUE,
    workflowsPath: new URL('./workflows.js', import.meta.url).pathname,
    activities,
  });

  await worker.run();
}

main().catch((e) => {
  console.error(e);
  process.exit(1);
});
