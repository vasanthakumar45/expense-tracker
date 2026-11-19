#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/ids.env"
[ -f "$OUT" ] || { echo "ERROR: $OUT not found."; exit 1; }
source "$OUT"
for v in ECR_URI DB_ENDPOINT DB_NAME DB_USER DB_PARAM BUCKET ACCOUNT_ID REGION; do
  [ -n "${!v:-}" ] || { echo "ERROR: $v is missing in ids.env. Finish the earlier steps."; exit 1; }
done
if grep -q '^TASKDEF_ARN=' "$OUT"; then
  echo "ERROR: this script already ran (TASKDEF_ARN is in $OUT)."
  exit 1
fi

IMAGE_TAG="${IMAGE_TAG:-manual-1}"
CLUSTER=expense-cluster
FAMILY=expense-api
LOG_GROUP=/ecs/expense-tracker
EXEC_ROLE=expense-task-execution-role
TASK_ROLE=expense-task-role
PARAM_ARN="arn:aws:ssm:${REGION}:${ACCOUNT_ID}:parameter${DB_PARAM}"

cat > /tmp/ecs-trust.json <<'JSON'
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Principal":{"Service":"ecs-tasks.amazonaws.com"},"Action":"sts:AssumeRole"}]}
JSON

echo "1/5 Creating the task execution role ..."
aws iam create-role --role-name "$EXEC_ROLE" \
  --assume-role-policy-document file:///tmp/ecs-trust.json \
  --tags Key=Project,Value=expense-tracker >/dev/null
aws iam attach-role-policy --role-name "$EXEC_ROLE" \
  --policy-arn arn:aws:iam::aws:policy/service-role/AmazonECSTaskExecutionRolePolicy
cat > /tmp/exec-ssm.json <<EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"ssm:GetParameters","Resource":"$PARAM_ARN"}]}
EOF
aws iam put-role-policy --role-name "$EXEC_ROLE" --policy-name read-db-password \
  --policy-document file:///tmp/exec-ssm.json

echo "2/5 Creating the task role (S3 write access to reports/ only) ..."
aws iam create-role --role-name "$TASK_ROLE" \
  --assume-role-policy-document file:///tmp/ecs-trust.json \
  --tags Key=Project,Value=expense-tracker >/dev/null
cat > /tmp/task-s3.json <<EOF
{"Version":"2012-10-17","Statement":[{"Effect":"Allow","Action":"s3:PutObject","Resource":"arn:aws:s3:::$BUCKET/reports/*"}]}
EOF
aws iam put-role-policy --role-name "$TASK_ROLE" --policy-name write-reports \
  --policy-document file:///tmp/task-s3.json

EXEC_ROLE_ARN="$(aws iam get-role --role-name "$EXEC_ROLE" --query Role.Arn --output text)"
TASK_ROLE_ARN="$(aws iam get-role --role-name "$TASK_ROLE" --query Role.Arn --output text)"

echo "3/5 Creating the log group (7 days of retention) ..."
aws logs create-log-group --log-group-name "$LOG_GROUP" --tags Project=expense-tracker
aws logs put-retention-policy --log-group-name "$LOG_GROUP" --retention-in-days 7

echo "4/5 Creating the ECS cluster ..."
aws ecs create-cluster --cluster-name "$CLUSTER" --tags key=Project,value=expense-tracker >/dev/null

echo "Waiting 15 seconds for the new roles to become usable everywhere ..."
sleep 15

echo "5/5 Registering the task definition ..."
cat > "$HERE/taskdef.json" <<EOF
{
  "family": "$FAMILY",
  "networkMode": "awsvpc",
  "requiresCompatibilities": ["FARGATE"],
  "cpu": "256",
  "memory": "512",
  "executionRoleArn": "$EXEC_ROLE_ARN",
  "taskRoleArn": "$TASK_ROLE_ARN",
  "runtimePlatform": {"cpuArchitecture": "X86_64", "operatingSystemFamily": "LINUX"},
  "containerDefinitions": [
    {
      "name": "api",
      "image": "$ECR_URI:$IMAGE_TAG",
      "essential": true,
      "portMappings": [{"containerPort": 5000, "protocol": "tcp"}],
      "environment": [
        {"name": "APP_ENV", "value": "aws"},
        {"name": "DB_HOST", "value": "$DB_ENDPOINT"},
        {"name": "DB_NAME", "value": "$DB_NAME"},
        {"name": "DB_USER", "value": "$DB_USER"},
        {"name": "DB_SSLMODE", "value": "require"},
        {"name": "S3_BUCKET", "value": "$BUCKET"},
        {"name": "AWS_DEFAULT_REGION", "value": "$REGION"}
      ],
      "secrets": [
        {"name": "DB_PASSWORD", "valueFrom": "$PARAM_ARN"}
      ],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "$LOG_GROUP",
          "awslogs-region": "$REGION",
          "awslogs-stream-prefix": "api"
        }
      }
    }
  ]
}
EOF
TASKDEF_ARN="$(aws ecs register-task-definition --cli-input-json "file://$HERE/taskdef.json" \
  --query taskDefinition.taskDefinitionArn --output text)"

cat >> "$OUT" <<EOF
CLUSTER=$CLUSTER
LOG_GROUP=$LOG_GROUP
EXEC_ROLE_ARN=$EXEC_ROLE_ARN
TASK_ROLE_ARN=$TASK_ROLE_ARN
TASKDEF_FAMILY=$FAMILY
TASKDEF_ARN=$TASKDEF_ARN
EOF

echo
echo "Done. Task definition: $TASKDEF_ARN"
