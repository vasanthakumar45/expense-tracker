#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/ids.env"
[ -f "$OUT" ] || { echo "ERROR: $OUT not found."; exit 1; }
source "$OUT"
[ -n "${TASKDEF_ARN:-}" ] || { echo "ERROR: run aws/04-ecs-base.sh first."; exit 1; }

DESIRED_COUNT="${DESIRED_COUNT:-2}"
SERVICE=expense-api

if ! grep -q '^ALB_DNS=' "$OUT"; then
  echo "1/4 Creating the target group ..."
  TG_ARN="$(aws elbv2 create-target-group --name expense-tg --protocol HTTP --port 5000 \
    --vpc-id "$VPC_ID" --target-type ip \
    --health-check-protocol HTTP --health-check-path /health \
    --health-check-interval-seconds 15 --health-check-timeout-seconds 5 \
    --healthy-threshold-count 2 --unhealthy-threshold-count 3 \
    --matcher HttpCode=200 --tags Key=Project,Value=expense-tracker \
    --query 'TargetGroups[0].TargetGroupArn' --output text)"
  aws elbv2 modify-target-group-attributes --target-group-arn "$TG_ARN" \
    --attributes Key=deregistration_delay.timeout_seconds,Value=30 >/dev/null

  echo "2/4 Creating the load balancer (about 2 to 3 minutes) ..."
  ALB_ARN="$(aws elbv2 create-load-balancer --name expense-alb --type application \
    --scheme internet-facing --subnets "$SUBNET_A" "$SUBNET_B" \
    --security-groups "$ALB_SG" --tags Key=Project,Value=expense-tracker \
    --query 'LoadBalancers[0].LoadBalancerArn' --output text)"
  aws elbv2 wait load-balancer-available --load-balancer-arns "$ALB_ARN"

  echo "3/4 Creating the listener on port 80 ..."
  aws elbv2 create-listener --load-balancer-arn "$ALB_ARN" --protocol HTTP --port 80 \
    --default-actions "Type=forward,TargetGroupArn=$TG_ARN" >/dev/null
  ALB_DNS="$(aws elbv2 describe-load-balancers --load-balancer-arns "$ALB_ARN" \
    --query 'LoadBalancers[0].DNSName' --output text)"
  cat >> "$OUT" <<EOF
TG_ARN=$TG_ARN
ALB_ARN=$ALB_ARN
ALB_DNS=$ALB_DNS
SERVICE=$SERVICE
EOF
  source "$OUT"
else
  echo "Load balancer already exists: $ALB_DNS"
fi

if aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
     --query 'services[?status==`ACTIVE`].serviceName' --output text | grep -q "$SERVICE"; then
  echo "The ECS service already exists."
else
  echo "4/4 Creating the ECS service with $DESIRED_COUNT task(s) ..."
  aws ecs create-service --cluster "$CLUSTER" --service-name "$SERVICE" \
    --task-definition "$TASKDEF_FAMILY" --desired-count "$DESIRED_COUNT" --launch-type FARGATE \
    --network-configuration "awsvpcConfiguration={subnets=[$SUBNET_A,$SUBNET_B],securityGroups=[$TASK_SG],assignPublicIp=ENABLED}" \
    --load-balancers "targetGroupArn=$TG_ARN,containerName=api,containerPort=5000" \
    --deployment-configuration '{"maximumPercent":200,"minimumHealthyPercent":100,"deploymentCircuitBreaker":{"enable":true,"rollback":true}}' \
    --health-check-grace-period-seconds 60 \
    --tags key=Project,value=expense-tracker >/dev/null
fi

echo "Waiting for the service to become stable (up to 10 minutes) ..."
aws ecs wait services-stable --cluster "$CLUSTER" --services "$SERVICE" \
  || echo "Not stable yet. Check the commands in 6.5."

echo
echo "Done. Application address: http://$ALB_DNS"
