# Section 1 — Architecture Sketch

**Architecture Diagram** 

```
  ┌──────────┐      ┌────────────────────────────────┐      ┌───────────────────┐
  │ Customer │ ───▶ │ public-api-server              │ ───▶ │ Temporal          │
  └──────────┘      │ (Keycloak + OAuth2 JWT,        │      │ StartWorkflow     │
                    │  token-exchange, rate limit)   │      │ (narrowed JWT in  │
                    └────────────────────────────────┘      │  workflow input)  │
                                                            └─────────┬─────────┘
                                                                      │
                    ┌────────────────────────────────┐                │
                    │ Warm Pool                      │ ◀──────────────┘
                    │ ┌────┐ ┌────┐ ┌────┐ ┌────┐    │   workers long-poll;
                    │ │pod │ │pod │ │pod │ │pod │ .. │   pods pre-warmed,
                    │ └────┘ └────┘ └─┬──┘ └────┘    │   Chromium up,
                    └─────────────────┼──────────────┘   no tenant role bound
                                      │
                              task delivered to
                              long-polling worker
                                      ▼
                    ┌────────────────────────────────┐
                    │ Agent Pod (gVisor)             │
                    │           ┌────────────┐       │
                    │           │  Browser   │       │
                    │           │ (Playwright│       │
                    │           │  + HAR)    │       │
                    │           └────────────┘       │
                    └──┬─────────┬───────┬──────┬────┘
                       │         │       │      │
                       │         │       │      └─────────────────────┐
                       ▼         ▼       ▼                            │
              ┌─────────────┐ ┌──────────────┐ ┌─────────────────┐    │
              │ LiteLLM     │ │ Shared       │ │ internal        │    │
              │ gateway     │ │ egress       │ │ api-server      │ ◀──┘
              │ (cache,     │ │ proxy        │ │ (claim tenant   │  claim
              │  budgets)   │ │              │ │  identity from  │  tenant
              │             │ │              │ │  Temporal,      │  identity
              │             │ │              │ │  typed DB ops,  │
              │             │ │              │ │  SET LOCAL      │
              │             │ │              │ │  app.tenant_id, │
              │             │ │              │ │  only DB-creds) │
              └─────────────┘ └──────┬───────┘ └────────┬────────┘
                                     │                  │
                                     ▼                  ▼
                            ┌────────────────┐ ┌────────────────────┐
                            │ external sites │ │ Postgres (RDS) via │
                            │ (regulators,   │ │ RDS Proxy          │
                            │  registries,   │ │ (FORCE ROW LEVEL   │
                            │  KYB providers)│ │  SECURITY)         │
                            └────────────────┘ └────────────────────┘

                    ┌────────────────────────────────┐
                    │ S3 WORM (Object Lock, 7-yr)    │ ◀── evidence write
                    │ HAR · screenshots · LLM I/O    │     direct from
                    │ · DB-write log · KMS-encrypted │     agent pod
                    └────────────────────────────────┘
                    ┌────────────────────────────────┐
                    │ OTel · Tempo · Mimir · Loki    │ ◀── trace_id propagated
                    │ (trace_id keyed evidence)      │     from api-server
                    └────────────────────────────────┘
```

**Compute substrate:** EKS + Karpenter + KEDA, with a **warm pool of single-tenant agent pods** sitting idle behind a Temporal workflow engine. Because you already run workloads on EKS, it's well-known ecosystem, good autoscaling, good for long-running tasks like your checks.

**Trigger → ready:** EKS pods scaled by KEDA, nodes by Karpenter. Pods long-poll a Temporal task queue. When a pod claims a task it calls the internal api-server, authenticating with its projected Kubernetes ServiceAccount token; the api-server returns a tenant-scoped JWT signed by Keycloak. 

**Cold-start budget:** The expected path is a **warm-pool hit**. KEDA holds `desired_replicas = active_tasks + reserve` permanently, so the steady-state arrival lands on a pod that already has Chromium up and is long-polling Temporal. Cases where no warm pod is available and Karpenter must provision a new node should be treated as exceptional, and the warm-capacity reserve is the main mechanism that keeps them rare.

**Scaling — three loops at three timescales:**

| Loop | Mechanism | Reacts in | Scales what |
|---|---|---|---|
| 1. Worker pool | **KEDA Temporal scaler** on `agent-tasks` queue depth + reserve | seconds | Warm-pool Deployment replicas |
| 2. Burst absorption | **Karpenter** NodePool, **on-demand only** at first, mixed `c7i/c7a/c6i.xlarge` | 25–40 s | EKS nodes |
| 3. Predictive pre-warm | Cron forecaster reads 7 d trigger volume from Prometheus, sets `minReplicaCount` on the KEDA `ScaledObject` for the next hour at `peak × 1.3` | hourly | Warm-pool |

**Identity & data scoping**

Identity is bound in **two stages**, and the trust boundary between them is the whole point:

- **Stage 1 — warm pod, idle.** No AWS IAM role for a tenant. No DB credentials. No tenant-scoped JWT. The pod has only what it needs to long-poll Temporal and to call the internal api-server's `BindIdentity` endpoint. A compromised idle pod has nothing to steal.
- **Stage 2 — task claimed.** The pod's first activity calls `BindIdentity(workflow_id, task_id)` on the internal api-server. The internal api-server **resolves the actual tenant_id by querying Temporal** for that workflow's input — the pod is not asked which tenant it serves and could not be believed if it answered. The internal api-server returns a narrowed task JWT minted via Keycloak token-exchange with `{tenant_id, task_id, trace_id, capabilities[]}` and a X-min TTL. That JWT is the pod's only credential for the run.

The data-layer gate is **Postgres RLS with `FORCE ROW LEVEL SECURITY`** on every customer-scoped data.

**Observability:** Public-api-server creates an OpenTelemetry trace_id when the trigger arrives. Temporal propagates it through the workflow and activities, so the same ID covers Playwright actions, LiteLLM calls, and internal-api-server DB writes. Logs are tagged with trace_id and tenant_id, allowing one trace ID to debug a task across services.

Stack: OTel SDK → Tempo for traces, Loki for logs, Prometheus for metrics.

An Evidence Service for writing S3 evidence bundles by trace_id may be added later, but better not to do in the initial scope.

# Section 2 — Pitfall matrix

| # | Risk | Mechanism in this design | Residual risk I accept |
|---|---|---|---|
| 1 | **Non-idempotent side effects** | Temporal workflow + activities (Restate / Camunda 8 may be considered. State and idempotency keys for every external side-effect call are persisted to Postgres before the call, so a retry reads the prior result instead of re-issuing it. | Vendors that ignore our idempotency key (some regulator portals can). For those, the activity is `maxAttempts=1` and a failure becomes a **human task** via a Temporal `humanDecision` Signal. |
| 2 | **Stuck agents** | Temporal activity heartbeats + `StartToCloseTimeout` per activity. A missing heartbeat times the activity out and routes to the same human-task path as risk #1. | False positives on legitimately slow tasks (a registrar that takes 9 min on a Friday). Mitigated by per-task-type timeout profiles, not a single global cap. |
| 3 | **Noisy neighbors and cost runaway** | LiteLLM can enforce per-tenant token-bucket on $/min, tokens/min, and concurrent calls. Scheduler caps tenant share of warm pool at min(20, 30%). Proxy quotas per tenant on bytes/min. Breach → 429 with Retry-After, alert to tenant + ops. | A bad tenant can still consume up to their daily budget in one minute. We accept that — a daily ceiling is the product knob, not an infra knob. |
| 4 | **Prompt injection from the open web** | The agent has no direct database access — it can only invoke tools exposed by the internal api-server, and its JWT capability list scopes those calls to a single tenant. Postgres RLS enforces the same boundary at the data layer independently. Cedar policies can be added later to describe what an arbitrary agent is allowed to do as a single auditable bundle. | The LLM can still be tricked into producing a bad-but-allowed action (filing the wrong form). |
| 5 | **Shared egress reputation** | A third-party provider such as Bright Data or Oxylabs can be considered, but this adds significant compliance, security, and reputational risk. Per-tenant infrastructure-level isolation may be required in the future. One possible approach is to implement it with a Kubernetes operator (custom CRD + controller that launches per-tenant proxy and sets network policies), but that would add significant complexity and engineering effort. For now, I would prefer to avoid this and keep it out of the initial scope. | One tenant's bad reputation still hurts that tenant's checks. We need to accept this blast radius. Bright Data may not be acceptable, oter solutions require huge engineering effort. |
| 6 | **Evidence and audit** | Every task writes a manifest to S3 with Object Lock in compliance mode (7-year retention): HAR, screenshot per action, full LLM input/output, DB write log, signed by KMS. Manifest indexed in a separate, append-only Postgres table by (tenant_id, trace_id, task_id). | Evidence storage cost. Mitigated by lifecycle-tiering bundles older than 90 days to Glacier. Engineering effort to implement. |
| 7 | **Vendor and model drift** | All LLM calls go through LiteLLM with explicit version pins (no latest, no aliases). New model = new workflow version → 1% canary against a golden replay set → automatic rollback on quality delta. For proxy / captcha / SMS, a vendor-health daemon runs a synthetic check every 60 s. Per-category vendor priority list with circuit breaker. | Silent quality regression.Failover to a backup vendor can significantly increase per-task cost — backups are usually pricier or slower. |
| 8 | **Long tasks outlive everything** | Workflow state lives in Temporal, not the pod - pod loss = activity retry from last checkpoint. The narrowed task JWT is 15 min; activities request a fresh exchanged token from Keycloak at the heartbeat boundary if a task runs longer. Deploys are handled with drainTimeout = maxTaskDuration; old pods finish in-flight work, new triggers go to fresh pods. STS / DB credentials live only inside the internal api-server (which deploys independently and uses its own rolling-refresh). | Pods stuck in graceful-drain for the full 15 min during a deploy slow rollouts. Deploys cost a warm-pool overlap window (~15 min × pool size). |
| 9 | **PII and secrets in observability** | Fluent Bit filters with regex + key-allowlist; default-deny on unknown fields. Screenshots pass through a DOM-aware redactor that masks input fields with type=password / data-sensitive. | Huge effort to implement and maintain. |
| 10 | **Blast radius across tenants** | Unit of isolation = one pod, one task, one tenant. gVisor on the runtime, narrowed JWT scoped to one tenant + one capability set, Postgres RLS (api-server sets app.tenant_id from verified JWT; agent pods talk to api-server, not Postgres directly). A poisoned input or compromised dep is contained to its pod's 10-min lifetime. DevSecOps practices to mitigate the risks must be implemented (SCA checks, golden images, etc.) | A bug in the api-server's tenant-scope or RLS-context middleware is a fleet-wide risk; mitigated by an integration test that asserts cross-tenant queries return zero rows. |
| 11 | **Lost work when an agent dies** | Temporal's "ack on activity completion" semantics: the trigger creates a workflow event before any agent sees it; a worker crash mid-activity becomes an activity retry, idempotency-keyed (see #1). | A task that crashes after a non-idempotent vendor call but before recording the result. |

## 3. ADR — Compute substrate

**Status:** Accepted
**Decision date:** 2026-06-19

### Context
Today's 2-min cold start is structural, not capacity. We need P50 < 3 s on triggers that fan out 30 s–10 min agent tasks driving real browsers and LLMs. We must keep tenant isolation enforced by infrastructure, not prompts.

### Options considered
1. **AWS Lambda/Step Functions with browser layer.** Cold start ~200 ms with provisioned concurrency. **Rejected:** 15-min hard ceiling has no margin for the 10-min P95 task; headless Chromium in Lambda is fragile; gVisor + EKS gives us a cleaner long-running execution model.
2. **EKS: kill-and-respawn pod per task, no warm pool**. Maximum isolation and maximum simplicity. Each pod is launched already bound to a specific tenant, so no tenant-binding mechanism through the API server is required. **Rejected:** Node launch + image pull + Chromium warm-up adds 60–120 seconds and misses the SLO.
3. **EKS pod reuse across tenants** (i.e., same pod runs Tenant A then Tenant B). **Rejected:** the moment a pod is reused, "compromised agent can't see another tenant's data" becomes a memory-hygiene story, not an infra story. Not acceptable.
5. **EKS warm pool of single-tenant pods, claim-on-trigger, destroy-on-end. ← chosen**

### Decision
Warm pool of single-tenant pods on EKS, gVisor-isolated, narrowed-JWT-scoped at claim time (no AWS credentials in the agent pod day one), destroyed at task end. Karpenter for node-level capacity. 

### Tradeoffs accepted
- **Warm pool + tenant isolation** requires additional engineering effort because a warm pod is not tied to a specific tenant when it starts. It can be assigned to any tenant. However, before processing a task, the pod must first claim and bind itself to that tenant. This tenant-claiming logic needs to be implemented separately.
- **Cost of idle warm capacity.** We over-provision by ~30% over forecast to absorb burst. At the target $/check this is acceptable; the pool size is the first lever I'd revisit (see §4).
- **Deploy latency.** Blue/green of the runtime image takes the longest in-flight task to drain — up to 15 min.
- **Pool-miss tail.** When burst exceeds reserve, Karpenter must spin a node — that's the P95, not the P50. We size reserve so the 1k burst is absorbed within the 8 s P95.
- **Operational surface.** EKS + Karpenter + Temporal + LiteLLM + Keycloak is a lot of moving parts. Justified because every piece is buy-not-build; we're composing, not authoring a runtime.

## 4. Cost model

### Target: **$0.80 per check**

at 200 concurrent / 5-min average task / 70% pool utilisation (~40k checks/day at steady state).

| Component | Cost / check | Notes / assumptions |
|---|---|---|
| **Compute** (warm pod + node share) | $0.05 | 1 vCPU + 2 GiB × 5 min avg, amortised over 70% utilisation. **On-demand only at first**; Spot for read-only workflow tier added later (see §5 Sequencing). |
| **LLM tokens** (Planner + Reader) | $0.45 | ~150k input / 15k output blended Sonnet 4.6 + Haiku, with prompt caching at 60% hit rate. Dominant line item. |
| **Egress / proxy** | $0.18 | Bright Data residential at $12/GB × ~15 MB/check + AWS NAT egress. Drops sharply if a tenant doesn't need residential. |
| **Vendor APIs** (captcha, SMS, KYB lookups) | $0.06 | Avg 1.5 captcha solves + occasional SMS; varies wildly by workflow. |
| **Storage** (S3 WORM evidence) | $0.005 | ~20 MB/check × $0.023/GB-mo, hot 30 d then Glacier. 7-yr WORM retention amortises cheaply. |
| **Observability** (traces, logs, metrics) | $0.03 | Sampled traces, structured logs with redaction, self-hosted Tempo + Mimir + Loki. |
| **Postgres + control plane share** | $0.025 | Amortised RDS + Temporal cluster + api-server. |
| **Total** | **$0.80** | |

LLM is the dominant line. Egress is second and is the most variable — a tenant on shared NAT pays ~$0.001 there, a tenant on residential Bright Data pays $0.18. The blended number assumes ~30% of checks need residential.

### Per-tenant ceiling

Two ceilings, both enforced at LiteLLM and the public api-server (row 3 of the pitfall matrix):

- **Daily cost cap** per tenant tier (free / silver / gold) — e.g. free $50/day, silver $2k/day, gold negotiated. On breach: triggers return `429` with `Retry-After: <seconds-to-midnight-UTC>`; in-flight workflows finish (no mid-task kills — that would create dirty state); Slack alert to tenant CSM + ops; tenant dashboard shows the cap line.

Above the cap, no infra spend continues. The tenant either lifts the cap (paid event) or waits for the daily reset.

### The lever I'd pull first if asked to halve unit cost

**Route the Reader model to Haiku and push prompt-cache hit rate to 90%.** The LLM line is $0.45/check — more than half the total. The Planner needs Sonnet's reasoning, but the Reader (which dominates input-token volume — page extraction, doc summarisation) rarely does. Swapping Reader to Haiku 4.5 with aggressive caching of the system prompt + tool definitions cuts that line from $0.45 to ~$0.12, saving **~$0.33/check** on its own. That alone takes us from $0.80 to $0.47, very close to halving.

If a second pull is needed, kill Bright Data dependency by helping tenants pre-arrange direct allowlists with their regulators (egress $0.18 → ~$0.02). Evidence WORM, observability, and compute are *not* the levers — cutting them costs us audit posture or SLO and wouldn't survive a real review.

## 5. Sequencing

### Week 1 — the smallest production-shaped slice

The goal: one tenant runs a real check end-to-end, on the new substrate, with the load-bearing security properties live.

- EKS cluster with Karpenter (on-demand only) + KEDA Temporal scaler.
- Warm pool of single-tenant pods, Chromium pre-booted, long-polling Temporal.
- Public + internal api-server.
- Keycloak HA with RFC 8693 token-exchange; pods authenticate to internal api-server via projected ServiceAccount token.
- Postgres with `FORCE ROW LEVEL SECURITY`, `SET LOCAL app.tenant_id` per transaction, runtime role with no `BYPASSRLS`. Internal api-server is the only DB caller.
- LiteLLM gateway with pinned model IDs (no `latest`).
- Shared NAT egress for everyone. No per-tenant proxies.
- Basic per-tenant daily cost cap, hard-coded per tier.

### Month 3 — survives the things that hurt at 200 concurrent

- OTel SDK in every service, `trace_id` minted at the public api-server and propagated through Temporal context into every activity.
- Tempo + Loki + Prometheus, self-hosted, behind Grafana.
- Idempotency keys for every external side-effect activity, persisted to Postgres before the call.
- Spot instances on the steady-state warm pool (~70% spot / 30% on-demand). Karpenter handles interruption; reserve covers the gap.
- Kubernetes `NetworkPolicy` per agent NodePool — egress allowed only to the LLM gateway, the internal api-server, and the tenant-pinned proxy. Replaces day-one VPC security-group restrictions with pod-level enforcement.
- Predictive pre-warm — cron forecaster reads 7 d trigger volume, sets `minReplicaCount` for the next hour at `peak × 1.3`.
- Reader-model migration to Haiku with 90% prompt-cache hit rate (the cost lever from §4). Validate with the LLM-canary harness below before promoting.

### Quarter 2 — what only matters once we have many tenants

- Vendor failover with circuit breaker (row 7) — primary captcha / proxy / SMS goes red → activity transparently fails to secondary; only when all are red does the queue pause and surface `VendorUnavailable` to the human-task path.
- Evidence Service — S3 with Object Lock (WORM, 7-yr), KMS-per-tenant, manifest indexed in append-only Postgres table by `(tenant_id, trace_id, task_id)`. Until this exists, evidence lives in the trace + per-task S3 prefix only.
- Log redaction at ingestion — Fluent Bit allowlist, default-deny on unknown fields. CI lint banning raw `log.Info(payload)` patterns.
- Cedar policy bundle — replace the ad-hoc `slices.Contains(capabilities, ...)` checks at the internal api-server with a Cedar policy set, so authorization can be reviewed and audited as a single artifact.
- Bright Data / Oxylabs integration as an opt-in tenant feature for regulators who block AWS IP ranges entirely. Documented compliance review per tenant before enabling.
- Multi-region or EU-residency cluster — only when a customer pays for it.

### What is explicitly **not** in Week 1, and why

- **Per-tenant proxies / Bright Data.** No tenant has yet asked for an allowlistable IP. Solving it before that ask is theatre — defer to first real demand.
- **Cedar / OPA policy engine.** Capability-list checks + RLS already meet the bar. Adding a policy engine before there's a real audit ask buys flexibility we cannot yet exercise.
- **Spot instances.** Spot interruptions during the first weeks would hide real bugs in pool sizing. Switch on once the pool is stable and we trust the reserve formula.
- **Multi-region.** AWS-only, single-region day one. Adding regions before traffic justifies it doubles the operational surface for no benefit.
- **Custom dashboards / NOC.** Grafana defaults + Tempo Explore + Loki Explore is enough for one on-call engineer at this volume. A custom UI is hand-wavy product work that should follow a real complaint, not precede one.

## 6. Threat model

Attacker fully controls one agent's LLM output and browser process. They still cannot:

1. **Read another tenant's data** — WT with `tenant_id` and Postgres RLS.
2. **Egress arbitrary destinations** — k8s NetworkPolicy + security groups.
3. **Persist beyond the pod's TTL** - no shared resources.
4. **Tamper with evidence** — S3 permissions.
5. **Hide its tracks in observability** 

## 7. What I'd refuse to build yet

1. **Multi-region active-active.** 99.9% is achievable single-region with multi-AZ. Active-active doubles complexity (data-residency, conflict resolution, Temporal cross-region replication, Postgres write-arbitration) for an SLO we don't yet need. Revisit only if a customer's contract requires it.
2. **Pod-per-tenant infra-level isolation via namespace + per-tenant proxy + custom CRD.** This is the strongest isolation model on paper — every tenant in their own namespace, NetworkPolicies fenced per tenant, dedicated proxy per tenant, all driven by a custom Kubernetes operator reconciling a `Tenant` CRD. **Refused.** It's months of operator engineering, a large operational surface (the operator itself becomes a tier-0 service), and we already get the security property we need from gVisor + RLS + JWT capabilities. For VIP customers who genuinely require it, the cleaner answer is a **dedicated single-tenant cluster** sold as a premium tier — not a general-purpose multi-tenant operator.
3. **Custom residential-proxy network.** Regulated, abuse-prone, capital-heavy business. Bright Data / Oxylabs already operate at scale. We pay the markup and stay focused on compliance-infra, not on becoming a proxy company.
4. **Custom agent runtime / browser sandbox.** Playwright + gVisor covers it. Building a bespoke headless-Chromium fork for "performance" or "stealth" is six engineer-quarters of yak-shaving for a marginal win. If Playwright is genuinely the bottleneck, we add Chromium DevTools Protocol shortcuts before forking anything.
5. **Custom workflow engine.** Temporal solves it. Restate / Camunda 8 are real alternatives (called out in row 1). Writing our own state machine + retry + replay engine because "Temporal feels heavy" is the worst kind of NIH.
6. **In-house LLM serving.** No. We compose hosted models via LiteLLM. Self-hosting Llama-class models gets attractive only above ~$5M/yr LLM spend; we're three orders of magnitude away from that.
7. **Cross-tenant fairness scheduler with weighted-fair-queueing.** Nice in theory, complicated in practice (you have to define "fair" — by trigger, by token, by dollar, by tier). Day-one daily cost cap + concurrency caps in §4 cover the actual failure mode (one tenant starves the rest). Only build this when a real incident proves the cap-based answer doesn't work.