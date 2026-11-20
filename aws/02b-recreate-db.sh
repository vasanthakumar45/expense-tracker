#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/ids.env"
[ -f "$OUT" ] || { echo "ERROR: $OUT not found."; exit 1; }
source "$OUT"
for v in DB_ID DB_NAME DB_USER DB_PARAM DB_SG SUBNET_A SUBNET_B; do
  [ -n "${!v:-}" ] || { echo "ERROR: $v is missing in ids.env."; exit 1; }
done

if aws rds describe-db-instances --db-instance-identifier "$DB_ID" >/dev/null 2>&1; then
  echo "ERROR: the database $DB_ID already exists. Nothing to recreate."
  exit 1
fi

DB_CLASS="${DB_CLASS:-db.t4g.micro}"

echo "1/4 Reading the password from SSM (or creating one if it is missing) ..."
if DB_PASS="$(aws ssm get-parameter --name "$DB_PARAM" --with-decryption \
      --query Parameter.Value --output text 2>/dev/null)"; then
  echo "    Using the existing password in $DB_PARAM"
else
  DB_PASS="$(openssl rand -hex 16)"
  aws ssm put-parameter --name "$DB_PARAM" --type SecureString --value "$DB_PASS" \
    --description "Expense Tracker database password" \
    --tags Key=Project,Value=expense-tracker >/dev/null
  echo "    Created a new password in $DB_PARAM"
fi

echo "2/4 Checking the DB subnet group ..."
aws rds describe-db-subnet-groups --db-subnet-group-name expense-db-subnets >/dev/null 2>&1 \
  || aws rds create-db-subnet-group --db-subnet-group-name expense-db-subnets \
       --db-subnet-group-description "Expense Tracker DB subnets" \
       --subnet-ids "$SUBNET_A" "$SUBNET_B" \
       --tags Key=Project,Value=expense-tracker >/dev/null

echo "3/4 Creating the RDS instance (about 5 to 15 minutes) ..."
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
  --tags Key=Project,Value=expense-tracker >/dev/null
unset DB_PASS
aws rds wait db-instance-available --db-instance-identifier "$DB_ID"

echo "4/4 Saving the new endpoint ..."
DB_ENDPOINT="$(aws rds describe-db-instances --db-instance-identifier "$DB_ID" \
  --query 'DBInstances[0].Endpoint.Address' --output text)"
sed -i '/^DB_ENDPOINT=/d' "$OUT"
echo "DB_ENDPOINT=$DB_ENDPOINT" >> "$OUT"

echo
echo "Done. New endpoint: $DB_ENDPOINT"
echo "Next: point the ECS service to this endpoint (step 5 of the instructions)."
