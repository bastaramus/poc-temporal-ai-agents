#!/usr/bin/env bash
# Build images, push to minikube's container runtime, helmfile apply.
# Run scripts/bootstrap-cluster.sh first (one-time). Re-run this script every
# time you change service code or values files.

set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NS="agent-poc"

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing tool: $1"; exit 1; }
}
require podman
require minikube
require kubectl
require helm
require helmfile

if ! minikube status --format '{{.Host}}' 2>/dev/null | grep -q Running; then
  echo "minikube is not running. Run scripts/bootstrap-cluster.sh first." >&2
  exit 1
fi

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

echo "==> Push images into the cluster"
# `minikube image load` accepts a tarball on stdin and works regardless of
# the cluster's container runtime (containerd, crio, docker).
podman save poc/public-api-server:dev   | minikube image load -
podman save poc/internal-api-server:dev | minikube image load -
podman save poc/worker:dev              | minikube image load -

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

echo
echo "==> Wait for core pods (this can take 3-5 minutes on first run)"
kubectl -n "$NS" wait --for=condition=Ready pod -l app.kubernetes.io/name=postgresql --timeout=300s || true
kubectl -n "$NS" wait --for=condition=Ready pod -l app.kubernetes.io/name=keycloakx   --timeout=300s || true

echo
echo "==> Temporal namespace"
# Single shared 'default' namespace — most Temporal Helm charts auto-create it
# during schema setup. If your chart doesn't, exec into admintools and run:
#   tctl --ns default namespace register --rd 1
ADMIN=$(kubectl -n "$NS" get pod -l app.kubernetes.io/component=admintools -o name | head -n1 || true)
if [[ -n "$ADMIN" ]]; then
  kubectl -n "$NS" exec "$ADMIN" -- tctl --ns default namespace describe >/dev/null 2>&1 \
    || kubectl -n "$NS" exec "$ADMIN" -- tctl --ns default namespace register --rd 1 || true
fi

echo
echo "==> Done."
echo "    next:  ./scripts/port-forward.sh   (or use 'f' on a service in k9s)"
echo "    tui:   k9s -n $NS"
