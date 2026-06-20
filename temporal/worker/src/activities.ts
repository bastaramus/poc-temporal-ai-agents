// Activities run on the worker pod. They handle anything non-deterministic:
// the projected SA token, the BindIdentity HTTP call, and the tool call.

import { Context } from '@temporalio/activity';
import { readFileSync } from 'node:fs';

const INTERNAL_API_URL = process.env.INTERNAL_API_URL!;
// k8s projects the SA token at this path when the volume mount is configured.
const SA_TOKEN_PATH = '/var/run/secrets/internal-api/token';

function readSaToken(): string {
  return readFileSync(SA_TOKEN_PATH, 'utf-8').trim();
}

export interface BindIdentityResult {
  access_token: string;
  expires_in: number;
  tenant_id: string;
}

export async function bindIdentity(args: {
  workflow_id: string;
}): Promise<BindIdentityResult> {
  const ctx = Context.current();
  const saToken = readSaToken();
  const res = await fetch(`${INTERNAL_API_URL}/bind-identity`, {
    method: 'POST',
    headers: {
      authorization: `Bearer ${saToken}`,
      'content-type': 'application/json',
    },
    body: JSON.stringify({
      workflow_id: args.workflow_id,
    }),
  });
  if (!res.ok) {
    throw new Error(`bind-identity failed: ${res.status} ${await res.text()}`);
  }
  ctx.log.info('bound identity from internal-api');
  return (await res.json()) as BindIdentityResult;
}

export async function callWriteDoc(args: {
  narrowed_jwt: string;
  title: string;
  content: string;
}): Promise<{ document_id: string }> {
  const res = await fetch(`${INTERNAL_API_URL}/tools/write-doc`, {
    method: 'POST',
    headers: {
      authorization: `Bearer ${args.narrowed_jwt}`,
      'content-type': 'application/json',
    },
    body: JSON.stringify({ title: args.title, content: args.content }),
  });
  if (!res.ok) throw new Error(`write-doc failed: ${res.status} ${await res.text()}`);
  return (await res.json()) as { document_id: string };
}

export async function callReadDoc(args: {
  narrowed_jwt: string;
  document_id: string;
}): Promise<{ found: boolean; document?: { id: string; title: string; content: string } }> {
  const res = await fetch(`${INTERNAL_API_URL}/tools/read-doc`, {
    method: 'POST',
    headers: {
      authorization: `Bearer ${args.narrowed_jwt}`,
      'content-type': 'application/json',
    },
    body: JSON.stringify({ document_id: args.document_id }),
  });
  if (!res.ok) throw new Error(`read-doc failed: ${res.status} ${await res.text()}`);
  return (await res.json()) as { found: boolean };
}
