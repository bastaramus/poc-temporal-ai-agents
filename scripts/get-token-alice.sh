#!/usr/bin/env bash
# Direct password grant for alice@tenant-a. Token is the end-user JWT used by
# /start-check on the public-api-server.
set -euo pipefail
KEYCLOAK="${KEYCLOAK_URL:-http://localhost:8080}"

curl -sf -X POST "$KEYCLOAK/realms/agent-poc/protocol/openid-connect/token" \
  -H "content-type: application/x-www-form-urlencoded" \
  -d "grant_type=password" \
  -d "client_id=public-api-client" \
  -d "username=alice" \
  -d "password=alice-password" \
  -d "scope=openid tenant" \
  | jq -r .access_token
