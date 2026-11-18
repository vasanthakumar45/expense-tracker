#!/bin/bash
set -euo pipefail

PROJECT=expense-tracker
OUT="$(cd "$(dirname "$0")" && pwd)/ids.env"

if [ -f "$OUT" ]; then
  echo "ERROR: $OUT already exists. The network was created before."
  echo "Delete the old resources first, or remove that file if you are sure."
  exit 1
fi

tags() { echo "ResourceType=$1,Tags=[{Key=Name,Value=$2},{Key=Project,Value=$PROJECT}]"; }

MY_IP="$(curl -s https://checkip.amazonaws.com | tr -d '[:space:]')"
ALLOW_CIDR="${ALLOW_CIDR:-${MY_IP}/32}"
if ! echo "$ALLOW_CIDR" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+/[0-9]+$'; then
  echo "ERROR: could not detect your IP. Run: ALLOW_CIDR=1.2.3.4/32 bash aws/01-network.sh"
  exit 1
fi
echo "Region : $(aws configure get region)"
echo "Allowed: $ALLOW_CIDR (can reach the load balancer)"

AZS=($(aws ec2 describe-availability-zones --query "AvailabilityZones[?State=='available'].ZoneName" --output text))
AZ1=${AZS[0]}
AZ2=${AZS[1]}
echo "Zones  : $AZ1 and $AZ2"

echo "Creating VPC..."
VPC_ID=$(aws ec2 create-vpc --cidr-block 10.20.0.0/16 \
  --tag-specifications "$(tags vpc expense-vpc)" --query Vpc.VpcId --output text)
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-support '{"Value":true}'
aws ec2 modify-vpc-attribute --vpc-id "$VPC_ID" --enable-dns-hostnames '{"Value":true}'

echo "Creating internet gateway..."
IGW_ID=$(aws ec2 create-internet-gateway \
  --tag-specifications "$(tags internet-gateway expense-igw)" \
  --query InternetGateway.InternetGatewayId --output text)
aws ec2 attach-internet-gateway --internet-gateway-id "$IGW_ID" --vpc-id "$VPC_ID"

echo "Creating subnets..."
SUBNET_A=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block 10.20.1.0/24 \
  --availability-zone "$AZ1" --tag-specifications "$(tags subnet expense-public-a)" \
  --query Subnet.SubnetId --output text)
SUBNET_B=$(aws ec2 create-subnet --vpc-id "$VPC_ID" --cidr-block 10.20.2.0/24 \
  --availability-zone "$AZ2" --tag-specifications "$(tags subnet expense-public-b)" \
  --query Subnet.SubnetId --output text)

echo "Creating route table..."
RT_ID=$(aws ec2 create-route-table --vpc-id "$VPC_ID" \
  --tag-specifications "$(tags route-table expense-public-rt)" \
  --query RouteTable.RouteTableId --output text)
aws ec2 create-route --route-table-id "$RT_ID" --destination-cidr-block 0.0.0.0/0 \
  --gateway-id "$IGW_ID" >/dev/null
aws ec2 associate-route-table --route-table-id "$RT_ID" --subnet-id "$SUBNET_A" >/dev/null
aws ec2 associate-route-table --route-table-id "$RT_ID" --subnet-id "$SUBNET_B" >/dev/null

echo "Creating security groups..."
ALB_SG=$(aws ec2 create-security-group --group-name expense-alb-sg \
  --description "Load balancer: HTTP from allowed IP" --vpc-id "$VPC_ID" \
  --tag-specifications "$(tags security-group expense-alb-sg)" --query GroupId --output text)
TASK_SG=$(aws ec2 create-security-group --group-name expense-task-sg \
  --description "API tasks: port 5000 from the load balancer" --vpc-id "$VPC_ID" \
  --tag-specifications "$(tags security-group expense-task-sg)" --query GroupId --output text)
DB_SG=$(aws ec2 create-security-group --group-name expense-db-sg \
  --description "Database: port 5432 from the API tasks" --vpc-id "$VPC_ID" \
  --tag-specifications "$(tags security-group expense-db-sg)" --query GroupId --output text)

aws ec2 authorize-security-group-ingress --group-id "$ALB_SG" \
  --protocol tcp --port 80 --cidr "$ALLOW_CIDR" >/dev/null
aws ec2 authorize-security-group-ingress --group-id "$TASK_SG" \
  --protocol tcp --port 5000 --source-group "$ALB_SG" >/dev/null
aws ec2 authorize-security-group-ingress --group-id "$DB_SG" \
  --protocol tcp --port 5432 --source-group "$TASK_SG" >/dev/null

cat > "$OUT" <<EOF
VPC_ID=$VPC_ID
IGW_ID=$IGW_ID
SUBNET_A=$SUBNET_A
SUBNET_B=$SUBNET_B
RT_ID=$RT_ID
ALB_SG=$ALB_SG
TASK_SG=$TASK_SG
DB_SG=$DB_SG
EOF

echo
echo "Done. IDs saved to $OUT"
cat "$OUT"
