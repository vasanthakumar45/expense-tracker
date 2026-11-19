#!/bin/bash
set -euo pipefail
: "${TAG:?}"
ALB_NAME="${ALB_NAME:-expense-alb}"

HOST="$(aws elbv2 describe-load-balancers --names "$ALB_NAME" \
  --query 'LoadBalancers[0].DNSName' --output text)"
BASE="http://$HOST"
echo "Testing $BASE and expecting version $TAG"

for i in $(seq 1 25); do
  VERSION="$(curl -fsS --max-time 5 "$BASE/version" 2>/dev/null || true)"
  if echo "$VERSION" | grep -q "\"version\":\"$TAG\""; then break; fi
  if [ "$i" -eq 25 ]; then
    echo "FAIL: /version did not return $TAG (last answer: ${VERSION:-none})"
    exit 1
  fi
  sleep 4
done
echo "PASS /version -> $VERSION"
echo "$VERSION" | grep -q '"env":"aws"' || { echo "FAIL: wrong environment"; exit 1; }

curl -fsS --max-time 5 "$BASE/health" >/dev/null && echo "PASS /health"
curl -fsS --max-time 10 "$BASE/expenses/summary" >/dev/null && echo "PASS /expenses/summary (the database answers)"
echo "Smoke test passed"
