#!/bin/bash
set -euo pipefail
: "${CLUSTER:?}" "${SERVICE:?}" "${FAMILY:?}" "${ECR_URI:?}" "${TAG:?}"
HERE="$(cd "$(dirname "$0")" && pwd)"

PREV_ARN="$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[0].taskDefinition' --output text)"
echo "$PREV_ARN" > .prev_taskdef
echo "Revision running now: $PREV_ARN"

# Copy the running revision and change only the image and the version variable
aws ecs describe-task-definition --task-definition "$PREV_ARN" --query taskDefinition --output json \
  | jq --arg IMG "$ECR_URI:$TAG" --arg TAG "$TAG" '
      {family, taskRoleArn, executionRoleArn, networkMode, containerDefinitions,
       volumes, requiresCompatibilities, cpu, memory, runtimePlatform}
      | .containerDefinitions[0].image = $IMG
      | .containerDefinitions[0].environment |=
          (map(select(.name != "APP_VERSION")) + [{name: "APP_VERSION", value: $TAG}])' \
  > new-taskdef.json

NEW_ARN="$(aws ecs register-task-definition --cli-input-json file://new-taskdef.json \
  --query taskDefinition.taskDefinitionArn --output text)"
echo "New revision: $NEW_ARN"

aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" --task-definition "$NEW_ARN" >/dev/null
echo "Waiting for the rollout (up to 10 minutes) ..."
if ! aws ecs wait services-stable --cluster "$CLUSTER" --services "$SERVICE"; then
  echo "FAIL: the service did not become stable."
  bash "$HERE/rollback.sh" || true
  exit 1
fi

CURRENT="$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[0].taskDefinition' --output text)"
STATE="$(aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
  --query 'services[0].deployments[?status==`PRIMARY`].rolloutState | [0]' --output text)"
if [ "$CURRENT" != "$NEW_ARN" ] || [ "$STATE" != "COMPLETED" ]; then
  echo "FAIL: rollout state is $STATE and the service runs $CURRENT (expected $NEW_ARN)."
  echo "The deployment circuit breaker has probably rolled back already."
  bash "$HERE/rollback.sh" || true
  exit 1
fi
echo "Deployed $NEW_ARN with image $ECR_URI:$TAG"
