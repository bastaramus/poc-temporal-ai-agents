#!/usr/bin/env bash
# Forward Keycloak (8080), public-api-server (8081), internal-api-server (8082),
# Temporal Web (8088). Ctrl-C kills all.
set -euo pipefail
NS="agent-poc"

trap 'kill $(jobs -p) 2>/dev/null || true' EXIT

kubectl -n "$NS" port-forward svc/keycloak-keycloakx-http  8080:8080 &
kubectl -n "$NS" port-forward svc/public-api-server        8081:8080 &
kubectl -n "$NS" port-forward svc/internal-api-server      8082:8080 &
kubectl -n "$NS" port-forward svc/temporal-web             8088:8080 || true &

echo "Keycloak:           http://localhost:8080"
echo "public-api-server:  http://localhost:8081"
echo "internal-api-server http://localhost:8082"
echo "Temporal UI:        http://localhost:8088"
wait
