#!/bin/bash
set -euo pipefail

PROJECT=expense-tracker
HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/ids.env"
[ -f "$OUT" ] || { echo "ERROR: $OUT not found. Run aws/01-network.sh first."; exit 1; }
source "$OUT"
if grep -q '^DB_ENDPOINT=' "$OUT"; then
  echo "ERROR: the data layer already exists (DB_ENDPOINT is in $OUT)."
  exit 1
fi

REGION="$(aws configure get region)"
ACCOUNT_ID="$(aws sts get-caller-identity --query Account --output text)"
BUCKET="expense-tracker-reports-${ACCOUNT_ID}-${REGION}"
DB_ID=expense-db
DB_NAME=expenses
DB_USER=expadmin
DB_CLASS="${DB_CLASS:-db.t4g.micro}"
PARAM=/expense-tracker/db-password

echo "Region: $REGION   Account: $ACCOUNT_ID   DB class: $DB_CLASS"

echo "1/5 Creating the S3 bucket $BUCKET ..."
aws s3api create-bucket --bucket "$BUCKET" --region "$REGION" \
  --create-bucket-configuration "LocationConstraint=$REGION" >/dev/null
aws s3api put-public-access-block --bucket "$BUCKET" \
  --public-access-block-configuration BlockPublicAcls=true,IgnorePublicAcls=true,BlockPublicPolicy=true,RestrictPublicBuckets=true
aws s3api put-bucket-encryption --bucket "$BUCKET" \
  --server-side-encryption-configuration '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
aws s3api put-bucket-tagging --bucket "$BUCKET" \
  --tagging "TagSet=[{Key=Project,Value=$PROJECT}]"
cat > /tmp/expense-lifecycle.json <<'JSON'
{"Rules":[{"ID":"expire-reports","Status":"Enabled","Filter":{"Prefix":"reports/"},"Expiration":{"Days":30}}]}
JSON
aws s3api put-bucket-lifecycle-configuration --bucket "$BUCKET" \
  --lifecycle-configuration file:///tmp/expense-lifecycle.json

echo "2/5 Generating the database password and storing it in SSM ..."
DB_PASS="$(openssl rand -hex 16)"
aws ssm put-parameter --name "$PARAM" --type SecureString --value "$DB_PASS" \
  --description "Expense Tracker database password" \
  --tags "Key=Project,Value=$PROJECT" >/dev/null

echo "3/5 Creating the DB subnet group ..."
aws rds create-db-subnet-group --db-subnet-group-name expense-db-subnets \
  --db-subnet-group-description "Expense Tracker DB subnets" \
  --subnet-ids "$SUBNET_A" "$SUBNET_B" \
  --tags "Key=Project,Value=$PROJECT" >/dev/null

echo "4/5 Creating the RDS instance (takes about 5 to 15 minutes) ..."
aws rds create-db-instance \
  --db-instance-identifier "$DB_ID" \
  --engine postgres \
  --db-instance-class "$DB_CLASS" \
  --allocated-storage 20 --storage-type gp3 --storage-encrypted \
  --db-name "$DB_NAME" \
  --master-username "$DB_USER" --master-user-password "$DB_PASS" \
  --db-subnet-group-name expense-db-subnets \
  --vpc-security-group-ids "$DB_SG" \
  --no-publicly-accessible --no-multi-az \
  --backup-retention-period 1 \
  --no-deletion-protection \
  --tags "Key=Project,Value=$PROJECT" >/dev/null
unset DB_PASS

aws rds wait db-instance-available --db-instance-identifier "$DB_ID"

echo "5/5 Reading the endpoint ..."
DB_ENDPOINT="$(aws rds describe-db-instances --db-instance-identifier "$DB_ID" \
  --query 'DBInstances[0].Endpoint.Address' --output text)"

cat >> "$OUT" <<EOF
ACCOUNT_ID=$ACCOUNT_ID
REGION=$REGION
BUCKET=$BUCKET
DB_ID=$DB_ID
DB_NAME=$DB_NAME
DB_USER=$DB_USER
DB_PARAM=$PARAM
DB_ENDPOINT=$DB_ENDPOINT
EOF

echo
echo "Done."
echo "Database endpoint: $DB_ENDPOINT"
echo "S3 bucket        : $BUCKET"
echo "Password         : stored in SSM at $PARAM (not printed)"
