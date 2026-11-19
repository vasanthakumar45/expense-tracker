#!/bin/bash
set -euo pipefail
: "${CLUSTER:?}" "${SERVICE:?}"
[ -f .prev_taskdef ] || { echo "No previous revision recorded."; exit 1; }
PREV_ARN="$(cat .prev_taskdef)"
echo "Rolling back to $PREV_ARN"
aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" --task-definition "$PREV_ARN" >/dev/null
aws ecs wait services-stable --cluster "$CLUSTER" --services "$SERVICE" \
  || echo "WARNING: the rollback is not stable yet. Check the ECS console."
echo "Service is back on $PREV_ARN"
