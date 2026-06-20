#!/usr/bin/env bash
# Build images, push to minikube's container runtime, helmfile apply.
# Run scripts/bootstrap-cluster.sh first (one-time). Re-run this script every
# time you change service code or values files.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS="agent-poc"

# ── Flags ──────────────────────────────────────────────────────────────
# Skip stages individually when iterating. Examples:
#   ./scripts/install.sh --skip-build          # don't rebuild images
#   ./scripts/install.sh --skip-load           # build but don't push to cluster
#   ./scripts/install.sh --skip-build --skip-load   # only re-apply helm/configmaps
#   ./scripts/install.sh --skip-helm           # only build/push, no helmfile apply
# Env-var equivalents (handy for `make` overrides): SKIP_BUILD=1 SKIP_LOAD=1 SKIP_HELM=1
SKIP_BUILD="${SKIP_BUILD:-0}"
SKIP_LOAD="${SKIP_LOAD:-0}"
SKIP_HELM="${SKIP_HELM:-0}"

usage() {
  cat <<EOF
Usage: $0 [--skip-build] [--skip-load] [--skip-helm] [-h|--help]

  --skip-build   skip podman build of the three service images
  --skip-load    skip pushing images into the minikube cluster
  --skip-helm    skip namespace+configmaps+helmfile apply

Env vars: SKIP_BUILD=1, SKIP_LOAD=1, SKIP_HELM=1 (same effect).
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    --skip-build) SKIP_BUILD=1 ;;
    --skip-load)  SKIP_LOAD=1 ;;
    --skip-helm)  SKIP_HELM=1 ;;
    -h|--help)    usage; exit 0 ;;
    *)            echo "unknown flag: $1" >&2; usage; exit 1 ;;
  esac
  shift
done

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing tool: $1"; exit 1; }
}
require minikube
require kubectl
require helm
require helmfile
[[ "$SKIP_BUILD" == 1 ]] || require podman

if ! minikube status --format '{{.Host}}' 2>/dev/null | grep -q Running; then
  echo "minikube is not running. Run scripts/bootstrap-cluster.sh first." >&2
  exit 1
fi

if [[ "$SKIP_BUILD" == 1 ]]; then
  echo "==> [skipped] Build service images"
else
  echo "==> Build service images in the rootful podman machine"
  # `minikube podman-env` only works for clusters running the `crio` runtime;
  # this cluster uses `containerd`, so we build locally (against the user's
  # existing rootful podman machine) and then ship the images into the cluster
  # with `minikube image load`. That works for any container runtime.
  #
  # Detect the cluster node arch (arm64 on Apple Silicon, amd64 on Intel) and
  # build for that — `minikube image load` rejects mismatched-arch tarballs.
  NODE_ARCH=$(kubectl get nodes -o jsonpath='{.items[0].status.nodeInfo.architecture}' 2>/dev/null || echo amd64)
  PLATFORM="${PODMAN_PLATFORM:-linux/${NODE_ARCH}}"
  echo "    platform: $PLATFORM"
  podman build --platform "$PLATFORM" -t poc/public-api-server:dev   "$ROOT/services/public-api-server"
  podman build --platform "$PLATFORM" -t poc/internal-api-server:dev "$ROOT/services/internal-api-server"
  podman build --platform "$PLATFORM" -t poc/worker:dev              "$ROOT/temporal/worker"
fi

if [[ "$SKIP_LOAD" == 1 ]]; then
  echo "==> [skipped] Push images into the cluster"
  RELOADED=0
else
  echo "==> Push images into the cluster"
  # `minikube image load` accepts a tarball on stdin and works regardless of
  # the cluster's container runtime (containerd, crio, docker).
  podman save poc/public-api-server:dev   | minikube image load -
  podman save poc/internal-api-server:dev | minikube image load -
  podman save poc/worker:dev              | minikube image load -
  RELOADED=1
fi

if [[ "$SKIP_HELM" == 1 ]]; then
  echo "==> [skipped] Namespace + ConfigMaps + helmfile apply"
else
  echo "==> Create namespace"
  kubectl create namespace "$NS" --dry-run=client -o yaml | kubectl apply -f -

  echo "==> ConfigMap: Postgres migrations"
  kubectl -n "$NS" create configmap poc-migrations \
    --from-file="$ROOT/db/001_init.sql" \
    --from-file="$ROOT/db/002_rls.sql" \
    --from-file="$ROOT/db/003_seed.sql" \
    --dry-run=client -o yaml | kubectl apply -f -

  echo "==> ConfigMap: Keycloak realm"
  kubectl -n "$NS" create configmap keycloak-realm \
    --from-file="$ROOT/keycloak/realm-export.json" \
    --dry-run=client -o yaml | kubectl apply -f -

  echo "==> helmfile apply"
  cd "$ROOT"
  helmfile apply --skip-diff-on-install
fi

# `helmfile apply` only restarts a Deployment when the rendered manifest
# changes; rebuilt images with the same :dev tag don't change the manifest.
# Force a rollout so the cluster actually picks up the freshly-loaded image.
# Skipped when images weren't reloaded (no point bouncing pods that have
# nothing new to pull) or when the user passed --skip-helm.
if [[ "${RELOADED:-0}" == 1 && "$SKIP_HELM" != 1 ]]; then
  echo "==> Roll the three services to pick up new images"
  for D in public-api-server internal-api-server worker; do
    kubectl -n "$NS" rollout restart "deploy/$D" 2>/dev/null || true
  done
fi

echo
echo "==> Wait for Postgres"
kubectl -n "$NS" wait --for=condition=Ready pod -l app.kubernetes.io/name=postgresql --timeout=300s || true

# Bitnami's initdb scripts only run on a *fresh* PVC. If the PVC already
# existed from a previous install, new SQL would silently never apply — roles,
# side databases, RLS policies, anything. So re-run the migrations every time;
# they're written to be idempotent (CREATE * IF NOT EXISTS, ON CONFLICT, etc).
echo "==> Apply DB migrations (idempotent)"
PG_POD=$(kubectl -n "$NS" get pod -l app.kubernetes.io/name=postgresql -o name | head -n1 | sed 's|pod/||' || true)
if [[ -n "$PG_POD" ]]; then
  for SQL in 001_init.sql 002_rls.sql 003_seed.sql; do
    echo "    $SQL"
    kubectl -n "$NS" exec -i "$PG_POD" -- env PGPASSWORD=change-me-postgres \
      psql -U postgres -v ON_ERROR_STOP=1 < "$ROOT/db/$SQL" >/dev/null
  done
  # If keycloak DB just got created, bounce Keycloak so it picks it up.
  if ! kubectl -n "$NS" get pod -l app.kubernetes.io/name=keycloakx -o jsonpath='{.items[0].status.phase}' 2>/dev/null | grep -q Running; then
    kubectl -n "$NS" rollout restart sts/keycloak-keycloakx 2>/dev/null || true
  fi
fi

echo "==> Wait for Keycloak"
kubectl -n "$NS" wait --for=condition=Ready pod -l app.kubernetes.io/name=keycloakx --timeout=300s || true

echo
echo "==> Temporal namespace"
# Single shared 'default' namespace.
#   admintools >= 1.30 ships the new `temporal` CLI (no tctl).
#   admintools <  1.30 ships only `tctl`.
# We try the new one first and fall back. The frontend is reachable in-cluster
# at temporal-frontend:7233.
ADMIN=$(kubectl -n "$NS" get pod -l app.kubernetes.io/component=admintools -o name | head -n1 || true)
if [[ -n "$ADMIN" ]]; then
  if kubectl -n "$NS" exec "$ADMIN" -- which temporal >/dev/null 2>&1; then
    kubectl -n "$NS" exec "$ADMIN" -- \
      temporal --address temporal-frontend:7233 operator namespace describe default >/dev/null 2>&1 \
      || kubectl -n "$NS" exec "$ADMIN" -- \
        temporal --address temporal-frontend:7233 operator namespace create \
          --retention 24h default || true
  elif kubectl -n "$NS" exec "$ADMIN" -- which tctl >/dev/null 2>&1; then
    kubectl -n "$NS" exec "$ADMIN" -- tctl --ns default namespace describe >/dev/null 2>&1 \
      || kubectl -n "$NS" exec "$ADMIN" -- tctl --ns default namespace register --rd 1 || true
  else
    echo "    (no temporal/tctl CLI in admintools — namespace 'default' is usually auto-registered by the chart)"
  fi
fi

echo
echo "==> Done."
echo "    next:  ./scripts/port-forward.sh   (or use 'f' on a service in k9s)"
echo "    tui:   k9s -n $NS"
