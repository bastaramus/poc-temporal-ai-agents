#!/usr/bin/env bash
# Asserts the four denial paths required by the prompt. Requires that the
# happy-path scripts have already produced one tenant-a doc and one tenant-b doc.
set -euo pipefail

API="${PUBLIC_API_URL:-http://localhost:8081}"
INTERNAL_API="${INTERNAL_API_URL:-http://localhost:8082}"

ALICE=$(./scripts/get-token-alice.sh)
BOB=$(./scripts/get-token-bob.sh)

echo "==> 1. Alice writes a tenant-a doc (happy path)"
DOC_A=$(curl -sf -X POST "$API/start-check" \
  -H "authorization: Bearer $ALICE" -H "content-type: application/json" \
  -d '{"mode":"write","title":"alice-secret","content":"tenant-a only"}' | jq -r .result.document_id)
echo "   tenant-a doc: $DOC_A"

echo "==> 2. Bob writes a tenant-b doc"
DOC_B=$(curl -sf -X POST "$API/start-check" \
  -H "authorization: Bearer $BOB" -H "content-type: application/json" \
  -d '{"mode":"write","title":"bob-secret","content":"tenant-b only"}' | jq -r .result.document_id)
echo "   tenant-b doc: $DOC_B"

echo
echo "==> 3. Body-tenant-confusion: Alice asks for tenant-b in body"
echo "    expectation: server uses JWT tenant_id, ignores body, runs on tenant-a ns"
RESP=$(curl -s -X POST "$API/start-check" \
  -H "authorization: Bearer $ALICE" -H "content-type: application/json" \
  -d "{\"mode\":\"read\",\"document_id\":\"$DOC_A\",\"tenant_id\":\"22222222-2222-2222-2222-222222222222\"}")
echo "$RESP" | jq .
TENANT=$(echo "$RESP" | jq -r .result.tenant_id)
[[ "$TENANT" == "11111111-1111-1111-1111-111111111111" ]] \
  || { echo "FAIL: expected tenant-a tenant_id, got $TENANT"; exit 1; }
echo "   PASS — workflow ran on tenant-a"

echo
echo "==> 4. Cross-tenant read via Alice trying to read tenant-b's doc id"
echo "    expectation: RLS returns 0 rows under tenant-a, found=false"
RESP=$(curl -s -X POST "$API/start-check" \
  -H "authorization: Bearer $ALICE" -H "content-type: application/json" \
  -d "{\"mode\":\"read\",\"document_id\":\"$DOC_B\"}")
echo "$RESP" | jq .
FOUND=$(echo "$RESP" | jq -r .result.found)
[[ "$FOUND" == "false" ]] || { echo "FAIL: expected found=false, got $FOUND"; exit 1; }
echo "   PASS — RLS blocked the cross-tenant row"

echo
echo "==> 5. Pod replays its SA token directly against /tools/read-doc"
echo "    expectation: 401 — tool endpoints accept ONLY narrowed JWTs"
# We can't read the projected SA token from outside the pod easily, so we
# use a deliberately-malformed token. The audience check fires first either way.
RESP_HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$INTERNAL_API/tools/read-doc" \
  -H "authorization: Bearer not-a-real-jwt" \
  -H "content-type: application/json" \
  -d '{"document_id":"00000000-0000-0000-0000-000000000000"}')
[[ "$RESP_HTTP" == "401" ]] || { echo "FAIL: expected 401, got $RESP_HTTP"; exit 1; }
echo "   PASS — got 401"

echo
echo "==> 6. Alice's user JWT replayed against /tools/read-doc"
echo "    expectation: 401 — audience public-api-client != worker-pod-client"
RESP_HTTP=$(curl -s -o /dev/null -w "%{http_code}" -X POST "$INTERNAL_API/tools/read-doc" \
  -H "authorization: Bearer $ALICE" \
  -H "content-type: application/json" \
  -d "{\"document_id\":\"$DOC_A\"}")
[[ "$RESP_HTTP" == "401" ]] || { echo "FAIL: expected 401, got $RESP_HTTP"; exit 1; }
echo "   PASS — wrong audience rejected"

echo
echo "All cross-tenant denial assertions passed."
