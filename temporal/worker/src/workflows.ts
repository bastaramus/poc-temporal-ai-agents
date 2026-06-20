import { proxyActivities, workflowInfo } from '@temporalio/workflow';
import type * as activities from './activities.js';

const acts = proxyActivities<typeof activities>({
  startToCloseTimeout: '30 seconds',
  retry: { maximumAttempts: 3 },
});

export interface StartCheckInput {
  tenant_id: string;
  user_sub: string;
  mode: 'read' | 'write';
  title?: string;
  content?: string;
  document_id?: string;
}

export async function StartCheckWorkflow(input: StartCheckInput) {
  const info = workflowInfo();

  // 1. Bind identity. The pod gives Temporal-resolvable info; the api-server
  //    rederives tenant_id from the workflow memo. Pod cannot self-declare.
  const bound = await acts.bindIdentity({
    workflow_id: info.workflowId,
  });

  // 2. Call the right tool with the narrowed JWT.
  if (input.mode === 'write') {
    if (!input.title || !input.content) {
      throw new Error('write requires title+content');
    }
    const r = await acts.callWriteDoc({
      narrowed_jwt: bound.access_token,
      title: input.title,
      content: input.content,
    });
    return { mode: 'write', tenant_id: bound.tenant_id, document_id: r.document_id };
  }

  if (!input.document_id) throw new Error('read requires document_id');
  const r = await acts.callReadDoc({
    narrowed_jwt: bound.access_token,
    document_id: input.document_id,
  });
  return { mode: 'read', tenant_id: bound.tenant_id, found: r.found, document: r.document };
}
