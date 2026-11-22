#!/usr/bin/env bash
# End-to-end checks against a running stack (local or AWS):
#   TARGET=https://localhost:8443 INSECURE=1 ./scripts/smoke.sh     # local, self-signed
#   TARGET=https://soge.labs.athoria.fr ./scripts/smoke.sh            # AWS
set -euo pipefail
: "${TARGET:?}"
C=(curl -sS --tlsv1.3); [ "${INSECURE:-0}" = 1 ] && C+=(-k)
pass() { printf '  \033[32mPASS\033[0m %s\n' "$1"; }
fail() { printf '  \033[31mFAIL\033[0m %s\n' "$1"; exit 1; }

[ "$("${C[@]}" -o /dev/null -w '%{http_code}' "$TARGET/")" = 200 ] && pass "UI served over TLS 1.3" || fail "UI"
K=(); [ "${INSECURE:-0}" = 1 ] && K=(-k)
if curl -sS "${K[@]}" --tls-max 1.2 -o /dev/null "$TARGET/" 2>/dev/null; then fail "TLS 1.2 accepted"; else pass "TLS 1.2 refused"; fi
"${C[@]}" -D - -o /dev/null "$TARGET/" | grep -qi '^content-security-policy:' && pass "security headers" || fail "CSP header missing"

TOKEN=$("${C[@]}" -X POST "$TARGET/x/s" | jq -r .token); [ -n "$TOKEN" ] && pass "session token" || fail "session"
AUTH=(-H "Authorization: Bearer $TOKEN")
if [ "${INSECURE:-0}" = 1 ]; then
  pass "(local: DEV_AUTH replaces the Lambda authorizer, no token check)"
else
  [ "$("${C[@]}" -o /dev/null -w '%{http_code}' "$TARGET/x/q?p=EURUSD")" = 401 ] && pass "quote refused without token (401)" || fail "quote must require a token"
fi
Q=$("${C[@]}" "${AUTH[@]}" "$TARGET/x/q?p=EURUSD"); echo "$Q" | jq -e '.bid < .ask' >/dev/null && pass "quote $(echo "$Q" | jq -r '.pair+" "+(.bid|tostring)+"/"+(.ask|tostring)+" "+.source')" || fail "quote"

KEY=$(uuidgen 2>/dev/null || cat /proc/sys/kernel/random/uuid)
BODY=$(jq -nc --arg q "$(echo "$Q" | jq -r .token)" '{quote:$q, side:"BUY", notional:100000}')
H=(-H 'Content-Type: application/json' -H "Idempotency-Key: $KEY")
R1=$("${C[@]}" "${AUTH[@]}" "${H[@]}" -w '\n%{http_code}' -d "$BODY" "$TARGET/x/d")
R2=$("${C[@]}" "${AUTH[@]}" "${H[@]}" -w '\n%{http_code}' -d "$BODY" "$TARGET/x/d")
[ "$(tail -1 <<<"$R1")" = 201 ] && pass "deal executed" || fail "execute: $R1"
[ "$(tail -1 <<<"$R2")" = 200 ] && [ "$(head -1 <<<"$R1" | jq -r .id)" = "$(head -1 <<<"$R2" | jq -r .id)" ] && pass "retry with same key returns the same deal (no duplicate)" || fail "idempotency: $R2"
BODY2=$(jq -c '.notional=200000' <<<"$BODY")
[ "$("${C[@]}" "${AUTH[@]}" "${H[@]}" -o /dev/null -w '%{http_code}' -d "$BODY2" "$TARGET/x/d")" = 422 ] && pass "same key, different payload rejected (422)" || fail "422 expected"
echo "All smoke checks passed."
