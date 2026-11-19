#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/ids.env"
source "$OUT"
for v in ACCOUNT_ID REGION ECR_REPO CLUSTER EXEC_ROLE_ARN TASK_ROLE_ARN LOG_GROUP; do
  [ -n "${!v:-}" ] || { echo "ERROR: $v missing in ids.env (finish Steps 4 to 6)."; exit 1; }
done

USER=jenkins-deployer
if aws iam get-user --user-name "$USER" >/dev/null 2>&1; then
  echo "ERROR: IAM user $USER already exists."
  exit 1
fi

cat > /tmp/jenkins-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {"Sid": "EcrLogin", "Effect": "Allow", "Action": "ecr:GetAuthorizationToken", "Resource": "*"},
    {"Sid": "EcrPushOneRepository", "Effect": "Allow",
     "Action": ["ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
                "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage",
                "ecr:GetDownloadUrlForLayer", "ecr:DescribeImages"],
     "Resource": "arn:aws:ecr:${REGION}:${ACCOUNT_ID}:repository/${ECR_REPO}"},
    {"Sid": "EcsTaskDefinitions", "Effect": "Allow",
     "Action": ["ecs:RegisterTaskDefinition", "ecs:DescribeTaskDefinition"], "Resource": "*"},
    {"Sid": "EcsOneService", "Effect": "Allow",
     "Action": ["ecs:UpdateService", "ecs:DescribeServices"],
     "Resource": "arn:aws:ecs:${REGION}:${ACCOUNT_ID}:service/${CLUSTER}/expense-api"},
    {"Sid": "EcsReadTasks", "Effect": "Allow",
     "Action": ["ecs:ListTasks", "ecs:DescribeTasks"], "Resource": "*"},
    {"Sid": "PassOnlyTheTwoTaskRoles", "Effect": "Allow", "Action": "iam:PassRole",
     "Resource": ["${EXEC_ROLE_ARN}", "${TASK_ROLE_ARN}"],
     "Condition": {"StringEquals": {"iam:PassedToService": "ecs-tasks.amazonaws.com"}}},
    {"Sid": "ReadLoadBalancer", "Effect": "Allow",
     "Action": ["elasticloadbalancing:DescribeLoadBalancers", "elasticloadbalancing:DescribeTargetHealth"],
     "Resource": "*"},
    {"Sid": "ReadAppLogs", "Effect": "Allow",
     "Action": ["logs:FilterLogEvents", "logs:GetLogEvents", "logs:DescribeLogStreams"],
     "Resource": "arn:aws:logs:${REGION}:${ACCOUNT_ID}:log-group:${LOG_GROUP}:*"}
  ]
}
EOF

aws iam create-user --user-name "$USER" --tags Key=Project,Value=expense-tracker >/dev/null
aws iam put-user-policy --user-name "$USER" --policy-name deploy-expense-tracker \
  --policy-document file:///tmp/jenkins-policy.json

echo
echo "User $USER created with a least-privilege policy."
echo "Creating its access key. The SECRET IS SHOWN ONLY ONCE:"
echo "-------------------------------------------------------"
aws iam create-access-key --user-name "$USER" \
  --query 'AccessKey.[AccessKeyId,SecretAccessKey]' --output text
echo "-------------------------------------------------------"
echo "Copy both values into Jenkins now (step 7.3), then run: clear"
