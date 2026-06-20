#!/usr/bin/env bash
# Direct password grant for alice@tenant-a. Token is the end-user JWT used by
# /start-check on the public-api-server.
set -euo pipefail
KEYCLOAK="${KEYCLOAK_URL:-http://localhost:8080}"
SCOPE="${KEYCLOAK_SCOPE:-openid profile tenant}"

RESP=$(curl -s -w "\n__HTTP__%{http_code}" -X POST \
  "$KEYCLOAK/realms/agent-poc/protocol/openid-connect/token" \
  -H "content-type: application/x-www-form-urlencoded" \
  -d "grant_type=password" \
  -d "client_id=public-api-client" \
  -d "username=alice" \
  -d "password=alice-password" \
  -d "scope=$SCOPE")

HTTP=${RESP##*__HTTP__}
BODY=${RESP%__HTTP__*}

if [[ "$HTTP" =~ ^2 ]]; then
  echo "$BODY" | jq -r .access_token
else
  echo "Keycloak returned HTTP $HTTP" >&2
  echo "$BODY" >&2
  exit 1
fi
