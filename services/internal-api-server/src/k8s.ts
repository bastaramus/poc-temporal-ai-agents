// k8s TokenReview — verifies a projected ServiceAccount token by asking the
// API server to authenticate it. The cluster signs and authoritatively answers
// "yes this token belongs to system:serviceaccount:<ns>:<sa>".
//
// This is what makes the BindIdentity flow safe even if a pod is compromised:
// the pod can't fake its own SA identity, only the kube-apiserver can vouch
// for the token.

import { KubeConfig, AuthenticationV1Api } from '@kubernetes/client-node';

const kc = new KubeConfig();

// In-cluster (default). Falls back to ~/.kube/config when running locally.
try {
  kc.loadFromCluster();
} catch {
  kc.loadFromDefault();
}

const auth = kc.makeApiClient(AuthenticationV1Api);

const ALLOWED_SAS = new Set(
  (process.env.ALLOWED_WORKER_SAS ?? '').split(',').map((s) => s.trim()).filter(Boolean)
);
const REQUIRED_AUDIENCE = process.env.SA_TOKEN_AUDIENCE ?? 'internal-api';

export async function verifyServiceAccountToken(
  token: string
): Promise<{ username: string }> {
  const review = await auth.createTokenReview({
    apiVersion: 'authentication.k8s.io/v1',
    kind: 'TokenReview',
    spec: {
      token,
      audiences: [REQUIRED_AUDIENCE],
    },
  });

  // 0.21+ returns the V1TokenReview directly (no .body wrapper). Some
  // versions still expose .body — handle both shapes defensively.
  const status =
    (review as any)?.status ?? (review as any)?.body?.status ?? undefined;
  if (!status?.authenticated) {
    throw new Error(`TokenReview not authenticated: ${status?.error ?? 'unknown'}`);
  }
  const username = status.user?.username ?? '';
  if (!ALLOWED_SAS.has(username)) {
    throw new Error(`SA ${username} not in ALLOWED_WORKER_SAS`);
  }
  return { username };
}
