#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/ids.env"
source "$OUT"
: "${ALERT_EMAIL:?Run it like this: ALERT_EMAIL=you@example.com bash aws/07-monitoring.sh}"
for v in ALB_ARN TG_ARN CLUSTER DB_ID REGION; do
  [ -n "${!v:-}" ] || { echo "ERROR: $v is missing in ids.env"; exit 1; }
done
if grep -q '^ALERT_TOPIC_ARN=' "$OUT"; then
  echo "ERROR: monitoring already exists (ALERT_TOPIC_ARN is in $OUT)."
  exit 1
fi

SERVICE=expense-api
LB_DIM="${ALB_ARN#*:loadbalancer/}"
TG_DIM="${TG_ARN##*:}"

echo "1/3 Creating the email topic ..."
TOPIC_ARN="$(aws sns create-topic --name expense-alerts \
  --tags Key=Project,Value=expense-tracker --query TopicArn --output text)"
aws sns subscribe --topic-arn "$TOPIC_ARN" --protocol email \
  --notification-endpoint "$ALERT_EMAIL" >/dev/null

put_alarm() {
  local name="$1" ns="$2" metric="$3" stat="$4" period="$5" evals="$6" threshold="$7" op="$8" desc="$9"
  shift 9
  aws cloudwatch put-metric-alarm --alarm-name "$name" --alarm-description "$desc" \
    --namespace "$ns" --metric-name "$metric" --dimensions "$@" \
    --statistic "$stat" --period "$period" --evaluation-periods "$evals" \
    --threshold "$threshold" --comparison-operator "$op" \
    --treat-missing-data notBreaching \
    --alarm-actions "$TOPIC_ARN" --ok-actions "$TOPIC_ARN" \
    --tags Key=Project,Value=expense-tracker
  echo "   alarm created: $name"
}

echo "2/3 Creating the alarms ..."
put_alarm expense-alb-5xx AWS/ApplicationELB HTTPCode_Target_5XX_Count Sum 300 1 5 \
  GreaterThanThreshold "More than 5 server errors in 5 minutes" \
  "Name=LoadBalancer,Value=$LB_DIM"
put_alarm expense-unhealthy-hosts AWS/ApplicationELB UnHealthyHostCount Maximum 60 2 1 \
  GreaterThanOrEqualToThreshold "At least one target is unhealthy" \
  "Name=TargetGroup,Value=$TG_DIM" "Name=LoadBalancer,Value=$LB_DIM"
put_alarm expense-ecs-cpu-high AWS/ECS CPUUtilization Average 60 3 80 \
  GreaterThanThreshold "Service CPU above 80 percent" \
  "Name=ClusterName,Value=$CLUSTER" "Name=ServiceName,Value=$SERVICE"
put_alarm expense-rds-cpu-high AWS/RDS CPUUtilization Average 300 2 80 \
  GreaterThanThreshold "Database CPU above 80 percent" \
  "Name=DBInstanceIdentifier,Value=$DB_ID"
put_alarm expense-rds-storage-low AWS/RDS FreeStorageSpace Minimum 300 1 2000000000 \
  LessThanThreshold "Less than about 2 GB of free database storage" \
  "Name=DBInstanceIdentifier,Value=$DB_ID"

echo "3/3 Creating the dashboard ..."
cat > /tmp/expense-dashboard.json <<EOF
{"widgets":[
 {"type":"metric","x":0,"y":0,"width":12,"height":6,"properties":{"title":"Requests and server errors","region":"$REGION","period":60,"stat":"Sum",
  "metrics":[["AWS/ApplicationELB","RequestCount","LoadBalancer","$LB_DIM"],["AWS/ApplicationELB","HTTPCode_Target_5XX_Count","LoadBalancer","$LB_DIM"]]}},
 {"type":"metric","x":12,"y":0,"width":12,"height":6,"properties":{"title":"Response time p95 (seconds)","region":"$REGION","period":60,"stat":"p95",
  "metrics":[["AWS/ApplicationELB","TargetResponseTime","LoadBalancer","$LB_DIM"]]}},
 {"type":"metric","x":0,"y":6,"width":12,"height":6,"properties":{"title":"Healthy and unhealthy targets","region":"$REGION","period":60,"stat":"Maximum",
  "metrics":[["AWS/ApplicationELB","HealthyHostCount","TargetGroup","$TG_DIM","LoadBalancer","$LB_DIM"],["AWS/ApplicationELB","UnHealthyHostCount","TargetGroup","$TG_DIM","LoadBalancer","$LB_DIM"]]}},
 {"type":"metric","x":12,"y":6,"width":12,"height":6,"properties":{"title":"ECS CPU and memory (percent)","region":"$REGION","period":60,"stat":"Average",
  "metrics":[["AWS/ECS","CPUUtilization","ClusterName","$CLUSTER","ServiceName","$SERVICE"],["AWS/ECS","MemoryUtilization","ClusterName","$CLUSTER","ServiceName","$SERVICE"]]}},
 {"type":"metric","x":0,"y":12,"width":12,"height":6,"properties":{"title":"Database CPU (percent) and connections","region":"$REGION","period":60,"stat":"Average",
  "metrics":[["AWS/RDS","CPUUtilization","DBInstanceIdentifier","$DB_ID"],["AWS/RDS","DatabaseConnections","DBInstanceIdentifier","$DB_ID"]]}}
]}
EOF
aws cloudwatch put-dashboard --dashboard-name expense-tracker \
  --dashboard-body file:///tmp/expense-dashboard.json >/dev/null

cat >> "$OUT" <<EOF
ALERT_TOPIC_ARN=$TOPIC_ARN
EOF

echo
echo "Done. Open your email and CLICK THE CONFIRMATION LINK from AWS Notifications."
echo "Alarms do not email you until the subscription is confirmed."
