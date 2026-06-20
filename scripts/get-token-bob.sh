#!/usr/bin/env bash
set -euo pipefail
KEYCLOAK="${KEYCLOAK_URL:-http://localhost:8080}"

curl -sf -X POST "$KEYCLOAK/realms/agent-poc/protocol/openid-connect/token" \
  -H "content-type: application/x-www-form-urlencoded" \
  -d "grant_type=password" \
  -d "client_id=public-api-client" \
  -d "username=bob" \
  -d "password=bob-password" \
  -d "scope=openid tenant" \
  | jq -r .access_token
