# poc-temporal-ai-agents

Minimal Kubernetes PoC of a multi-tenant agent platform that demonstrates two
load-bearing security properties:

1. **Keycloak token-exchange** — the internal-api-server mints a narrowed,
   short-lived task JWT from a broader identity (tenant-scoped, capability-scoped,
   15-minute TTL).
2. **Pod → api-server JWT auth** — the worker pod starts with **no tenant
   credentials**. To do anything tenant-scoped it must call `/bind-identity` on the
   internal-api-server, which authenticates the pod via its projected Kubernetes
   ServiceAccount token and resolves `tenant_id` by reading the workflow input from
   Temporal. The pod cannot self-declare which tenant it serves.

> This PoC is the security-skeleton from `SUMBISSION.md` Section 1. Warm pool,
> KEDA, Karpenter, gVisor, NetworkPolicy, OTel propagation, evidence WORM — out of
> scope here. See "Production hardening" at the bottom.

## Architecture (ASCII)

```
  curl                                                   ┌────────────────────┐
  (alice@tenant-a) ──▶ public-api-server ──────────────▶ │ Temporal (shared)  │
                       /start-check                       │ ns: default        │
                       - validates Keycloak JWT           │ queue: agent-tasks │
                       - extracts tenant_id from JWT      │ memo.tenant_id =   │
                       - StartWorkflow w/ tenant_id memo  │   <jwt tenant>     │
                                                          └─────────┬──────────┘
                                                                    │
                                                          ┌─────────▼──────────┐
                                                          │ Worker pod          │
                                                          │ (long-poll)         │
                                                          │ Has ONLY:           │
                                                          │  - projected SA tok │
                                                          │ Has NOT:            │
                                                          │  - DB creds         │
                                                          │  - tenant JWT       │
                                                          └─────────┬──────────┘
                                                                    │ claims task
                            ┌───────────────────────────────────────┘
                            │ POST /bind-identity
                            │   Authorization: Bearer <SA token>
                            │   { workflow_id, run_id }
                            ▼
                    ┌──────────────────────────────────────────────┐
                    │ internal-api-server (BindIdentity)           │
                    │ 1. k8s TokenReview — verify SA token         │
                    │ 2. DescribeWorkflowExecution(workflow_id)    │
                    │    read input → trusted tenant_id            │
                    │ 3. Keycloak token-exchange:                  │
                    │    subject_token  = service-account login    │
                    │    audience       = worker-pod-client        │
                    │    extra claims   = tenant_id, workflow_id,  │
                    │                     capabilities[]           │
                    │ 4. return narrowed task JWT (15-min TTL)     │
                    └──────────────────────────────────────────────┘
                            │
                            ▼ POST /tools/{read-doc,write-doc}
                              Authorization: Bearer <narrowed JWT>
                    ┌──────────────────────────────────────────────┐
                    │ internal-api-server (tool endpoints)         │
                    │ - JWKS verify, audience=worker-pod-client    │
                    │ - extract tenant_id from JWT (NOT body)      │
                    │ - BEGIN                                       │
                    │ - SET LOCAL app.tenant_id = <tenant_id>      │
                    │ - parameterized SQL                           │
                    │ - INSERT audit_log                            │
                    │ - COMMIT                                      │
                    └─────────┬─────────────────────────┬───────────┘
                              │                         │
                              ▼                         ▼
                    ┌──────────────────┐      ┌──────────────────┐
                    │ Postgres         │      │ Postgres         │
                    │ FORCE RLS        │      │ audit_log        │
                    │ documents/runs   │      │                  │
                    └──────────────────┘      └──────────────────┘
```

## Prerequisites (macOS, no Docker Desktop)

The PoC runs on **minikube** (with the **podman** driver) and uses **k9s** as
the cluster TUI. All tools come from Homebrew:

```sh
brew install podman minikube kubectl helm helmfile k9s jq curl
```

Resource minimums for the VM that hosts the cluster: **4 vCPU, 8 GiB RAM,
40 GiB disk.** Bump RAM to 12 GiB if you also turn on the Temporal Web UI.

> Apple Silicon vs. Intel: `scripts/install.sh` reads the cluster node's
> architecture (`kubectl get node -o jsonpath='{...architecture}'`) and passes
> the matching `--platform linux/{arm64|amd64}` to `podman build`. Override
> with `PODMAN_PLATFORM=linux/...` if you ever need to.

## Install (first run, end-to-end)

```sh
# 1. One-time: rootful podman machine + minikube cluster + kubectl context.
make bootstrap

# 2. Build the three service images directly into the cluster's runtime,
#    then helmfile-apply Postgres / Keycloak / Temporal / public-api /
#    internal-api / worker. Re-run after any code change.
make install

# 3. In another terminal — port-forwards for curl-based tests.
make pf

# 4. Or drive the cluster with k9s (recommended).
k9s
```

> **`make help`** lists every target — bootstrap, build, apply, restart,
> token-alice / token-bob, write-alice (`TITLE=... CONTENT=...`), read-alice
> (`DOC=...`), deny-test, psql, audit-tail, etc.

## Stop / start / nuke

```sh
minikube stop            # pause; preserves cluster state
minikube start           # resume
minikube delete          # nuke the cluster (next install needs bootstrap-cluster.sh again)

podman machine stop      # also stops the cluster
podman machine start
```

## Get tokens

```sh
# Alice belongs to tenant-a
ALICE=$(./scripts/get-token-alice.sh)
# Bob belongs to tenant-b
BOB=$(./scripts/get-token-bob.sh)
```

The tokens carry a `tenant_id` claim sourced from a custom Keycloak user attribute.

## Happy-path tests

```sh
# Alice writes a tenant-a document
DOC_ID=$(./scripts/start-check.sh "$ALICE" write "hello" "tenant-a secret" | jq -r .document_id)

# Alice reads it back
./scripts/start-check.sh "$ALICE" read "$DOC_ID"

# Bob does the same on tenant-b
DOC_ID_B=$(./scripts/start-check.sh "$BOB" write "hi" "tenant-b secret" | jq -r .document_id)
./scripts/start-check.sh "$BOB" read "$DOC_ID_B"
```

## Cross-tenant denial test

```sh
./scripts/cross-tenant-deny-test.sh
```

This script asserts four denials, each at the layer that blocked it:

1. Alice's `/start-check` body contains `"tenant_id": "tenant-b"` → public-api-server
   ignores body, uses JWT claim. Workflow runs on `tenant-a` namespace.
2. Alice's narrowed JWT replayed against a `document_id` that belongs to tenant-b →
   internal-api-server: `BEGIN; SET LOCAL app.tenant_id='tenant-a'; SELECT ... WHERE id=$1`
   returns zero rows because RLS filters out the tenant-b row. `audit_log` records
   `decision=deny, reason=not_found_under_tenant`.
3. Worker pod calls `/tools/read-doc` directly with its SA token → 401: tool endpoints
   require a narrowed JWT, not an SA token.
4. Worker pod tampers with the narrowed JWT (changes `tenant_id` claim) → JWKS
   signature verification fails.

## How tenant isolation works (defense in depth)

| Layer | Mechanism | What it stops |
|---|---|---|
| Public API | JWT validated against Keycloak JWKS; `tenant_id` taken from the verified claim, never from body | Client-side body tampering |
| Temporal memo | `tenant_id` is written to the workflow memo by public-api-server (server-side, from the verified JWT). The pod cannot influence it. | Pod self-declared tenancy |
| Pod identity | Pod has no tenant credentials at boot; `tenant_id` is resolved server-side from the workflow memo | Compromised idle pod has nothing to steal |
| Token exchange | Narrowed JWT scoped to one `tenant_id` and one capability set with a 15-min TTL | Long-lived blast radius |
| Internal API | JWT `aud=worker-pod-client` checked; tool endpoints require capability claim | Confused-deputy / wrong-audience replay |
| DB | `FORCE ROW LEVEL SECURITY` keyed on `current_setting('app.tenant_id')`, set by `SET LOCAL` from the verified JWT | Bug in app code that forgets to filter |

If any single layer fails, the next layer still blocks the access.

## How token exchange works in this repo

`keycloak/realm-export.json` enables RFC 8693 token-exchange:

- `internal-api-client` is a confidential client allowed to call the
  `urn:ietf:params:oauth:grant-type:token-exchange` grant.
- It targets `worker-pod-client` as the `audience` of the issued narrowed token.
- Custom claims (`tenant_id`, `workflow_id`, `capabilities`) are added by the
  internal-api-server and merged via the
  `urn:ietf:params:oauth:token-type:access_token` request.

The implementation lives at `services/internal-api-server/src/keycloak.ts`.

For the PoC the `subject_token` is the internal-api-server's own service-account
access token. In production the better pattern is to start from the user's JWT
and add tenant/workflow constraints via token-exchange — the structure of the
call is the same.

## How BindIdentity prevents pod self-declared tenant

`POST /bind-identity` does NOT accept a `tenant_id` field. Its only inputs are
`{ workflow_id, run_id }`. The server then:

```
const desc = await temporalClient.describe(workflow_id);
const tenant_id = desc.input[0].tenant_id;   // trusted: written by public-api-server
```

The worker pod cannot make the api-server believe it serves tenant-b just by
asking for tenant-b. Tenancy is resolved from Temporal, not from the pod.

## How Postgres RLS fits

`db/002_rls.sql` enables and **forces** RLS on every tenant-scoped table:

```sql
ALTER TABLE documents ENABLE ROW LEVEL SECURITY;
ALTER TABLE documents FORCE ROW LEVEL SECURITY;

CREATE POLICY tenant_isolation ON documents
  USING      (tenant_id = current_setting('app.tenant_id', true)::uuid)
  WITH CHECK (tenant_id = current_setting('app.tenant_id', true)::uuid);
```

The runtime role `app_runtime` is **not** a superuser, **not** the table owner,
and does **not** have `BYPASSRLS`. So even `SELECT * FROM documents` returns only
rows whose `tenant_id` matches the current `app.tenant_id` GUC.

Internal-api-server sets the GUC inside every transaction:

```sql
BEGIN;
SET LOCAL app.tenant_id = '...';
-- queries
COMMIT;
```

`SET LOCAL` is scoped to the transaction; the connection cannot leak the
previous tenant's setting to the next pooled checkout.

## How Temporal fits

- **One shared Temporal namespace** (`default`) and **one shared task queue**
  (`agent-tasks`). The tenant boundary lives in JWT + memo + RLS, not in
  Temporal routing. SUMBISSION.md §7 refuses operator-driven per-tenant
  infrastructure (CRDs, namespaces, proxies) — per-tenant Temporal namespaces
  are the same shape of complexity.
- Tenant scoping comes from the **workflow memo** (`memo.tenant_id`), set
  server-side by public-api-server from the verified JWT. The pod never sees
  or sets it.
- `StartCheckWorkflow` records `agent_runs` rows, calls the BindIdentity
  activity, then the tool activity, then updates `agent_runs`. Activity retries
  give us durable orchestration for free.
- If a tenant later needs hard isolation at the Temporal layer (rate limits,
  retention, RBAC), the upgrade is "give that tenant their own namespace" —
  the memo-based code path keeps working unchanged.

## What's intentionally simplified for PoC

| Simplified here | Production design |
|---|---|
| Single worker Deployment polling one shared `agent-tasks` queue | Warm pool of pods on the same shared queue, KEDA-scaled by queue depth (per-tenant queues only when a tenant has paid for tier-isolated capacity) |
| One Postgres role for runtime | Per-tenant DB role or per-tenant schema |
| Subject token in token-exchange = service-account login | Subject token = end-user JWT, narrowed by exchange |
| In-process audit_log writes | Append-only WORM bucket (S3 Object Lock) |
| No NetworkPolicies | Default-deny + per-tier egress allowlists |
| No gVisor / Kata | gVisor on the agent runtime (untrusted code paths) |
| No OTel propagation | trace_id minted at public api, propagated through Temporal context |
| Cedar deferred entirely (Quarter 2 in the SUBMISSION) | Cedar policy bundle replaces ad-hoc capability checks |

## Production hardening checklist

- Namespace per tenant in Kubernetes; NetworkPolicy default-deny.
- Worker deployment per tenant or per isolation tier; KEDA on queue depth.
- Per-tenant Temporal namespace **only** when a customer needs hard rate-limit
  / retention / RBAC isolation at the workflow layer. Default stays shared.
- Per-tenant DB role, schema, or DB; per-tenant KMS keys.
- Pod Security `restricted` profile; gVisor / Kata for untrusted-code activities.
- Token-exchange chained from end-user JWT, not service account.
- Short-lived everything: 15-min narrowed JWTs, IRSA/Workload-Identity STS.
- Audit log to WORM (S3 Object Lock, 7-yr); manifest indexed by trace_id.
- Rate limits at LiteLLM and the public api.
- Policy tests in CI; Cedar policy review process.
- Secret management via External Secrets / Vault; no plaintext in values files.
- No long-lived user JWT passed into workers.

## Exact commands

```sh
./scripts/bootstrap-cluster.sh                   # one-time
./scripts/install.sh                             # build + helmfile apply
./scripts/port-forward.sh                        # in another terminal
ALICE=$(./scripts/get-token-alice.sh)
BOB=$(./scripts/get-token-bob.sh)
./scripts/start-check.sh "$ALICE" write "hi" "tenant-a"
./scripts/start-check.sh "$ALICE" read "<doc_id>"
./scripts/cross-tenant-deny-test.sh
```

## Troubleshooting (macOS-specific)

| Symptom | Fix |
|---|---|
| `minikube start` complains "rootless not supported" | `podman machine stop && podman machine set --rootful && podman machine start` |
| First boot is slow | Normal — `podman machine init` downloads a Fedora CoreOS image (~700 MB). Subsequent starts are seconds. |
| `exec format error` in pod logs, or `minikube image load` says "does not match arch of the container runtime" | Image arch ≠ cluster arch. `scripts/install.sh` auto-detects from the node, so just re-run `make install`. To force a specific arch: `PODMAN_PLATFORM=linux/arm64 ./scripts/install.sh` (or `linux/amd64`). |
| `port-forward.sh` connections drop after a sleep | Kill it and rerun, or use k9s `f` (it auto-reconnects). |
| Pods stuck `ImagePullBackOff` for `poc/*:dev` | The `podman save \| minikube image load -` step didn't run or didn't reach the cluster. Re-run `make build` (or `./scripts/install.sh`) and check `minikube image ls \| grep poc/`. |
| `minikube podman-env` errors with "only compatible with crio runtime" | Expected — this cluster uses `containerd`. Build locally and use `podman save \| minikube image load -` instead, which is what `scripts/install.sh` and `make build` already do. |
| Out of memory: Keycloak or Temporal OOMKilled | Bump the VM: `minikube stop && minikube delete && VM_MEMORY_MIB=12288 ./scripts/bootstrap-cluster.sh`. |
| `helmfile apply` chart-version errors | Versions in `helmfile.yaml` are pinned with `# TODO`; update them to whatever your local cache resolves with `helm search repo bitnami/postgresql -l \| head`. |

