#!/usr/bin/env bash
# One-time cluster bootstrap for macOS: container engine + minikube.
# Tries podman first; falls back to docker if podman is not installed.
# Idempotent — safe to re-run.
set -euo pipefail

VM_CPUS="${VM_CPUS:-4}"
VM_MEMORY_MIB="${VM_MEMORY_MIB:-10976}"
VM_DISK_GIB="${VM_DISK_GIB:-40}"
K8S_VERSION="${K8S_VERSION:-v1.35.0}"

require() {
  command -v "$1" >/dev/null 2>&1 || { echo "Missing tool: $1. brew install $1"; exit 1; }
}

# ── Container engine detection ─────────────────────────────────────────
# Prefer podman (rootful machine on macOS works without Docker Desktop).
# Fall back to docker if podman is not installed.
if command -v podman >/dev/null 2>&1; then
  ENGINE=podman
  DRIVER=podman
elif command -v docker >/dev/null 2>&1; then
  ENGINE=docker
  DRIVER=docker
else
  echo "Missing tool: neither 'podman' nor 'docker' found. brew install podman (preferred) or install Docker Desktop." >&2
  exit 1
fi
echo "==> container engine: $ENGINE (minikube --driver=$DRIVER)"

require minikube
require kubectl
require helm
require helmfile
require jq

# helmfile uses `helm diff` under the hood. Install on first run, no-op after.
if ! helm plugin list 2>/dev/null | awk 'NR>1 {print $1}' | grep -qx diff; then
  echo "==> Installing helm-diff plugin"
  helm plugin install https://github.com/databus23/helm-diff --verify=false
fi

if [[ "$ENGINE" == podman ]]; then
  echo "==> podman machine"
  if ! podman machine list --format '{{.Name}} {{.Running}}' | grep -q 'true'; then
    if ! podman machine list --format '{{.Name}}' | grep -q .; then
      echo "    initialising rootful podman machine ($VM_CPUS CPU, $VM_MEMORY_MIB MiB, $VM_DISK_GIB GiB)"
      podman machine init --rootful --cpus "$VM_CPUS" --memory "$VM_MEMORY_MIB" --disk-size "$VM_DISK_GIB"
    else
      podman machine set --rootful || true
    fi
    podman machine start
  else
    echo "    podman machine already running"
  fi

  # Make sure the running machine is rootful (minikube podman driver requirement).
  if ! podman machine inspect --format '{{.Rootful}}' 2>/dev/null | grep -q true; then
    echo "    switching podman machine to rootful"
    podman machine stop
    podman machine set --rootful
    podman machine start
  fi
else
  echo "==> docker daemon"
  if ! docker info >/dev/null 2>&1; then
    echo "    docker is installed but the daemon isn't reachable. Start Docker Desktop and re-run." >&2
    exit 1
  fi
  echo "    docker daemon reachable"
fi

echo "==> minikube driver = $DRIVER"
minikube config set driver "$DRIVER" >/dev/null
if [[ "$ENGINE" == podman ]]; then
  minikube config set rootless false >/dev/null
fi

echo "==> minikube start"
if minikube status --format '{{.Host}}' 2>/dev/null | grep -q Running; then
  echo "    cluster already running — skipping start"
else
  minikube start \
    --driver="$DRIVER" \
    --container-runtime=containerd \
    --cpus="$VM_CPUS" \
    --memory="$VM_MEMORY_MIB" \
    --disk-size="${VM_DISK_GIB}g" \
    --kubernetes-version="$K8S_VERSION" \
    --addons=metrics-server
fi

echo "==> kubectl context"
kubectl config use-context minikube >/dev/null
kubectl get nodes

echo
echo "Cluster is ready. Next:"
echo "  ./scripts/install.sh           # build images, helmfile apply"
echo "  ./scripts/port-forward.sh      # in another terminal (or use k9s 'f')"
echo "  k9s -n agent-poc"
