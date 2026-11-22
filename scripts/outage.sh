#!/usr/bin/env bash
# Local failure drill: the database crashes, then comes back.
# Expected: quotes keep working (no DB on that path), deals get 503 + Retry-After,
# and after recovery the same Idempotency-Key executes exactly once.
# Runs from the host (it drives docker compose); HTTP calls go through the tools
# container so the host needs nothing but Docker.
set -euo pipefail
docker compose --profile tools up -d --wait tools >/dev/null
trap 'docker compose --profile tools stop tools >/dev/null 2>&1 || true' EXIT
x() { docker compose exec -T tools "$@"; }
T=https://api:8443; C="curl -sSk --tlsv1.3"

Q=$(x sh -c "$C '$T/x/q?p=EURUSD'")
KEY=$(x cat /proc/sys/kernel/random/uuid)
BODY=$(x jq -nc --arg q "$(x jq -r .token <<<"$Q")" '{quote:$q, side:"BUY", notional:100000}')
deal() { x sh -c "$C -D - -o /dev/null -H 'Content-Type: application/json' -H 'Idempotency-Key: $KEY' -d '$BODY' $T/x/d" | grep -iE '^HTTP|^retry-after' | tr -d '\r' | paste -sd' ' -; }

docker compose kill db >/dev/null; echo "database killed"
echo "  quote: $(x sh -c "$C -o /dev/null -w '%{http_code}' '$T/x/q?p=EURUSD'")   (expected 200)"
echo "  deal : $(deal)   (expected 503 + Retry-After)"
docker compose up -d --wait db >/dev/null; echo "database back"
echo "  deal : $(deal)   (expected 201)"
echo "  retry: $(deal)   (expected 200, same deal)"
