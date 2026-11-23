#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
source "$HERE/ids.env"
CLUSTER="${CLUSTER:-expense-cluster}"
SERVICE=expense-api
MIN_TASKS="${MIN_TASKS:-1}"
MAX_TASKS="${MAX_TASKS:-3}"
RESOURCE="service/${CLUSTER}/${SERVICE}"

aws application-autoscaling register-scalable-target \
  --service-namespace ecs --scalable-dimension ecs:service:DesiredCount \
  --resource-id "$RESOURCE" --min-capacity "$MIN_TASKS" --max-capacity "$MAX_TASKS"

cat > /tmp/scaling-policy.json <<'JSON'
{"TargetValue":50.0,
 "PredefinedMetricSpecification":{"PredefinedMetricType":"ECSServiceAverageCPUUtilization"},
 "ScaleOutCooldown":60,"ScaleInCooldown":120}
JSON
aws application-autoscaling put-scaling-policy \
  --service-namespace ecs --scalable-dimension ecs:service:DesiredCount \
  --resource-id "$RESOURCE" --policy-name expense-cpu-target \
  --policy-type TargetTrackingScaling \
  --target-tracking-scaling-policy-configuration file:///tmp/scaling-policy.json >/dev/null

echo "Autoscaling is on: $MIN_TASKS to $MAX_TASKS tasks, aiming for 50 percent CPU."
