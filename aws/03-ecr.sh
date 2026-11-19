#!/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
OUT="$HERE/ids.env"
[ -f "$OUT" ] || { echo "ERROR: $OUT not found."; exit 1; }
source "$OUT"
if grep -q '^ECR_URI=' "$OUT"; then
  echo "ERROR: the ECR repository was already created (ECR_URI is in $OUT)."
  exit 1
fi

REGION="${REGION:-$(aws configure get region)}"
ACCOUNT_ID="${ACCOUNT_ID:-$(aws sts get-caller-identity --query Account --output text)}"
REPO=expense-tracker

echo "Creating ECR repository $REPO ..."
aws ecr create-repository --repository-name "$REPO" \
  --image-scanning-configuration scanOnPush=true \
  --image-tag-mutability IMMUTABLE \
  --encryption-configuration encryptionType=AES256 \
  --tags Key=Project,Value=expense-tracker >/dev/null

cat > /tmp/ecr-lifecycle.json <<'JSON'
{"rules":[{"rulePriority":1,"description":"Keep only the last 10 images","selection":{"tagStatus":"any","countType":"imageCountMoreThan","countNumber":10},"action":{"type":"expire"}}]}
JSON
aws ecr put-lifecycle-policy --repository-name "$REPO" \
  --lifecycle-policy-text file:///tmp/ecr-lifecycle.json >/dev/null

ECR_REGISTRY="${ACCOUNT_ID}.dkr.ecr.${REGION}.amazonaws.com"
cat >> "$OUT" <<EOF
ECR_REPO=$REPO
ECR_REGISTRY=$ECR_REGISTRY
ECR_URI=$ECR_REGISTRY/$REPO
EOF

echo "Done. Repository: $ECR_REGISTRY/$REPO"
