#!/usr/bin/env bash
# Usage:
#   start-check.sh <jwt> write <title> <content>
#   start-check.sh <jwt> read  <document_id>
set -euo pipefail
API="${PUBLIC_API_URL:-http://localhost:8081}"

JWT="${1:?jwt required}"
MODE="${2:?mode required (read|write)}"

if [[ "$MODE" == "write" ]]; then
  TITLE="${3:?title required}"
  CONTENT="${4:?content required}"
  BODY=$(jq -nc --arg t "$TITLE" --arg c "$CONTENT" '{mode:"write", title:$t, content:$c}')
elif [[ "$MODE" == "read" ]]; then
  DOC_ID="${3:?document_id required}"
  BODY=$(jq -nc --arg id "$DOC_ID" '{mode:"read", document_id:$id}')
else
  echo "unknown mode $MODE" >&2; exit 1
fi

curl -sf -X POST "$API/start-check" \
  -H "authorization: Bearer $JWT" \
  -H "content-type: application/json" \
  -d "$BODY" | jq .
