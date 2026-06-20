#!/usr/bin/env bash
# Drop and recreate the keycloak database so `start-dev --import-realm` re-runs
# on the next pod boot. Use after editing keycloak/realm-export.json.
#
# Idempotent and fast — Keycloak rebuilds its schema in ~15s.
set -euo pipefail
NS="${NS:-agent-poc}"

echo "==> ConfigMap: Keycloak realm (refresh from disk)"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
kubectl -n "$NS" create configmap keycloak-realm \
  --from-file="$ROOT/keycloak/realm-export.json" \
  --dry-run=client -o yaml | kubectl apply -f -

echo "==> Scale Keycloak to 0 (release DB connections)"
kubectl -n "$NS" scale sts/keycloak-keycloakx --replicas=0
kubectl -n "$NS" wait --for=delete pod -l app.kubernetes.io/name=keycloakx --timeout=120s || true

echo "==> Terminate any lingering connections to keycloak DB"
kubectl -n "$NS" exec postgresql-0 -- env PGPASSWORD=change-me-postgres psql -U postgres -c "
  SELECT pg_terminate_backend(pid)
  FROM pg_stat_activity
  WHERE datname = 'keycloak' AND pid <> pg_backend_pid();" || true

echo "==> Drop and recreate the keycloak DB"
kubectl -n "$NS" exec postgresql-0 -- env PGPASSWORD=change-me-postgres \
  psql -U postgres -c 'DROP DATABASE IF EXISTS keycloak;'
kubectl -n "$NS" exec postgresql-0 -- env PGPASSWORD=change-me-postgres \
  psql -U postgres -c 'CREATE DATABASE keycloak;'

echo "==> Scale Keycloak back to 1 (~30s schema init + realm import)"
kubectl -n "$NS" scale sts/keycloak-keycloakx --replicas=1
kubectl -n "$NS" rollout status sts/keycloak-keycloakx --timeout=180s

echo "==> Done. Re-run 'make pf' if your port-forward dropped."
