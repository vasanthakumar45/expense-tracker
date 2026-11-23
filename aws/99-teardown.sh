#!/bin/bash
# Deletes everything created for the Expense Tracker project. Safe to run again.
set -u

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/ids.env"
[ -f "$OUT" ] && source "$OUT"

ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)" || exit 1
REGION="${REGION:-$(aws configure get region)}"
BUCKET="${BUCKET:-expense-tracker-reports-${ACCOUNT_ID}-${REGION}}"
CLUSTER="${CLUSTER:-expense-cluster}"
SERVICE=expense-api
FAILED=()
NF='notfound|not found|does not exist|nosuchentity|nosuchbucket|nosuchkey|invalidgroup\.notfound|invalidvpcid\.notfound|invalidsubnetid\.notfound|invalidroutetableid\.notfound'

run() {
  local desc="$1" tries="$2" delay="$3" i out
  shift 3
  for i in $(seq 1 "$tries"); do
    if out="$("$@" 2>&1)"; then echo "   ok: $desc"; return 0; fi
    if echo "$out" | grep -qiE "$NF"; then echo "   skip (not there): $desc"; return 0; fi
    [ "$i" -lt "$tries" ] && sleep "$delay"
  done
  echo "   FAILED: $desc"
  echo "$out" | head -3 | sed 's/^/      /'
  FAILED+=("$desc")
  return 1
}

echo "This will PERMANENTLY DELETE the Expense Tracker project:"
echo "  account $ACCOUNT_ID, region $REGION"
echo "  ECS service and cluster, load balancer, the RDS database AND ITS DATA,"
echo "  the S3 bucket and reports, ECR images, IAM roles and Jenkins user, the VPC."
echo "  (Set KEEP_SNAPSHOT=yes before running to keep a final database snapshot.)"
read -rp "Type DELETE to continue: " ANSWER
[ "$ANSWER" = "DELETE" ] || { echo "Cancelled. Nothing was deleted."; exit 1; }

echo; echo "== 1/10 Autoscaling and monitoring"
run "autoscaling target" 1 1 aws application-autoscaling deregister-scalable-target \
  --service-namespace ecs --scalable-dimension ecs:service:DesiredCount \
  --resource-id "service/${CLUSTER}/${SERVICE}"
run "alarms" 1 1 aws cloudwatch delete-alarms --alarm-names expense-alb-5xx \
  expense-unhealthy-hosts expense-ecs-cpu-high expense-rds-cpu-high expense-rds-storage-low
run "dashboard" 1 1 aws cloudwatch delete-dashboards --dashboard-names expense-tracker
if [ -n "${ALERT_TOPIC_ARN:-}" ]; then
  run "email topic" 1 1 aws sns delete-topic --topic-arn "$ALERT_TOPIC_ARN"
fi

echo; echo "== 2/10 ECS service, cluster and task definitions"
if aws ecs describe-services --cluster "$CLUSTER" --services "$SERVICE" \
     --query 'services[?status!=`INACTIVE`].serviceName' --output text 2>/dev/null | grep -q "$SERVICE"; then
  run "scale service to 0" 1 1 aws ecs update-service --cluster "$CLUSTER" --service "$SERVICE" --desired-count 0
  run "delete service" 1 1 aws ecs delete-service --cluster "$CLUSTER" --service "$SERVICE" --force
  aws ecs wait services-inactive --cluster "$CLUSTER" --services "$SERVICE" 2>/dev/null
fi
run "delete cluster" 6 15 aws ecs delete-cluster --cluster "$CLUSTER"
for td in $(aws ecs list-task-definitions --family-prefix expense-api --status ACTIVE \
              --query 'taskDefinitionArns[]' --output text 2>/dev/null); do
  run "deregister ${td##*/}" 1 1 aws ecs deregister-task-definition --task-definition "$td"
done

echo; echo "== 3/10 Load balancer and target group"
ALB="$(aws elbv2 describe-load-balancers --names expense-alb \
  --query 'LoadBalancers[0].LoadBalancerArn' --output text 2>/dev/null || true)"
if [ -n "$ALB" ] && [ "$ALB" != "None" ]; then
  run "delete load balancer" 1 1 aws elbv2 delete-load-balancer --load-balancer-arn "$ALB"
  aws elbv2 wait load-balancers-deleted --load-balancer-arns "$ALB" 2>/dev/null
fi
TG="$(aws elbv2 describe-target-groups --names expense-tg \
  --query 'TargetGroups[0].TargetGroupArn' --output text 2>/dev/null || true)"
if [ -n "$TG" ] && [ "$TG" != "None" ]; then
  run "delete target group" 8 15 aws elbv2 delete-target-group --target-group-arn "$TG"
fi

echo; echo "== 4/10 Database"
if aws rds describe-db-instances --db-instance-identifier expense-db >/dev/null 2>&1; then
  if [ "${KEEP_SNAPSHOT:-no}" = "yes" ]; then
    SNAP="expense-db-final-$(date +%Y%m%d-%H%M%S)"
    run "delete database (keeping snapshot $SNAP)" 1 1 aws rds delete-db-instance \
      --db-instance-identifier expense-db --final-db-snapshot-identifier "$SNAP" --delete-automated-backups
  else
    run "delete database (no snapshot)" 1 1 aws rds delete-db-instance \
      --db-instance-identifier expense-db --skip-final-snapshot --delete-automated-backups
  fi
  echo "   waiting for the database to disappear (5 to 10 minutes) ..."
  aws rds wait db-instance-deleted --db-instance-identifier expense-db 2>/dev/null
fi
run "delete DB subnet group" 6 20 aws rds delete-db-subnet-group --db-subnet-group-name expense-db-subnets

echo; echo "== 5/10 Image registry"
run "delete ECR repository" 1 1 aws ecr delete-repository --repository-name expense-tracker --force

echo; echo "== 6/10 Storage and secrets"
run "empty bucket" 1 1 aws s3 rm "s3://$BUCKET" --recursive
run "delete bucket" 1 1 aws s3api delete-bucket --bucket "$BUCKET"
run "delete password parameter" 1 1 aws ssm delete-parameter --name /expense-tracker/db-password
run "delete log group" 1 1 aws logs delete-log-group --log-group-name /ecs/expense-tracker

echo; echo "== 7/10 Jenkins IAM user"
if aws iam get-user --user-name jenkins-deployer >/dev/null 2>&1; then
  for k in $(aws iam list-access-keys --user-name jenkins-deployer --query 'AccessKeyMetadata[].AccessKeyId' --output text); do
    run "delete access key $k" 1 1 aws iam delete-access-key --user-name jenkins-deployer --access-key-id "$k"
  done
  for p in $(aws iam list-user-policies --user-name jenkins-deployer --query 'PolicyNames[]' --output text); do
    run "delete user policy $p" 1 1 aws iam delete-user-policy --user-name jenkins-deployer --policy-name "$p"
  done
  run "delete IAM user" 1 1 aws iam delete-user --user-name jenkins-deployer
fi

echo; echo "== 8/10 ECS IAM roles"
for role in expense-task-execution-role expense-task-role; do
  if aws iam get-role --role-name "$role" >/dev/null 2>&1; then
    for p in $(aws iam list-role-policies --role-name "$role" --query 'PolicyNames[]' --output text); do
      run "delete inline policy $p" 1 1 aws iam delete-role-policy --role-name "$role" --policy-name "$p"
    done
    for a in $(aws iam list-attached-role-policies --role-name "$role" --query 'AttachedPolicies[].PolicyArn' --output text); do
      run "detach ${a##*/}" 1 1 aws iam detach-role-policy --role-name "$role" --policy-arn "$a"
    done
    run "delete role $role" 1 1 aws iam delete-role --role-name "$role"
  fi
done

echo; echo "== 9/10 Network"
VPC="$(aws ec2 describe-vpcs --filters "Name=tag:Name,Values=expense-vpc" "Name=tag:Project,Values=expense-tracker" \
  --query 'Vpcs[0].VpcId' --output text 2>/dev/null || true)"
if [ -n "$VPC" ] && [ "$VPC" != "None" ]; then
  echo "   VPC $VPC: waiting for network interfaces to be released (up to 5 minutes) ..."
  for i in $(seq 1 20); do
    N="$(aws ec2 describe-network-interfaces --filters "Name=vpc-id,Values=$VPC" --query 'length(NetworkInterfaces)' --output text)"
    [ "$N" = "0" ] && break
    sleep 15
  done
  for name in expense-db-sg expense-task-sg expense-alb-sg; do
    SG="$(aws ec2 describe-security-groups --filters "Name=vpc-id,Values=$VPC" "Name=group-name,Values=$name" \
      --query 'SecurityGroups[0].GroupId' --output text)"
    if [ -n "$SG" ] && [ "$SG" != "None" ]; then
      run "delete security group $name" 10 15 aws ec2 delete-security-group --group-id "$SG"
    fi
  done
  RT="$(aws ec2 describe-route-tables --filters "Name=vpc-id,Values=$VPC" "Name=tag:Name,Values=expense-public-rt" \
    --query 'RouteTables[0].RouteTableId' --output text)"
  if [ -n "$RT" ] && [ "$RT" != "None" ]; then
    for assoc in $(aws ec2 describe-route-tables --route-table-ids "$RT" \
        --query 'RouteTables[0].Associations[?Main==`false`].RouteTableAssociationId' --output text); do
      run "disassociate route table" 1 1 aws ec2 disassociate-route-table --association-id "$assoc"
    done
    run "delete route table" 3 5 aws ec2 delete-route-table --route-table-id "$RT"
  fi
  IGW="$(aws ec2 describe-internet-gateways --filters "Name=attachment.vpc-id,Values=$VPC" \
    --query 'InternetGateways[0].InternetGatewayId' --output text)"
  if [ -n "$IGW" ] && [ "$IGW" != "None" ]; then
    run "detach internet gateway" 3 5 aws ec2 detach-internet-gateway --internet-gateway-id "$IGW" --vpc-id "$VPC"
    run "delete internet gateway" 3 5 aws ec2 delete-internet-gateway --internet-gateway-id "$IGW"
  fi
  for sn in $(aws ec2 describe-subnets --filters "Name=vpc-id,Values=$VPC" --query 'Subnets[].SubnetId' --output text); do
    run "delete subnet $sn" 6 15 aws ec2 delete-subnet --subnet-id "$sn"
  done
  run "delete VPC" 4 10 aws ec2 delete-vpc --vpc-id "$VPC"
else
  echo "   no project VPC found"
fi

echo; echo "== 10/10 Local files"
rm -f "$HERE/taskdef.json"
if [ ${#FAILED[@]} -eq 0 ]; then
  [ -f "$OUT" ] && mv "$OUT" "$OUT.deleted-$(date +%Y%m%d-%H%M%S)"
  echo
  echo "ALL DONE. Everything was deleted, and ids.env was set aside."
  echo "Now check the result with the commands in step 8.5."
else
  echo
  echo "FINISHED WITH ${#FAILED[@]} PROBLEM(S):"
  printf '  - %s\n' "${FAILED[@]}"
  echo "ids.env was kept. Run this script again: it skips what is already deleted."
  exit 1
fi
