#!/bin/bash
# Export Terraform outputs as environment variables and generate eksctl config
#
# Usage:
#   cd /home/ubuntu/aws-backup-test
#   ./eksctl-config/export-tf-outputs.sh [kubernetes_version]
#
# Example:
#   ./eksctl-config/export-tf-outputs.sh 1.32

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_ROOT="$(dirname "$SCRIPT_DIR")"
TERRAFORM_DIR="$PROJECT_ROOT/terraform"

# Colors
GREEN='\033[0;32m'
BLUE='\033[0;34m'
NC='\033[0m'

log_info() {
    echo -e "${BLUE}[INFO]${NC} $1"
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $1"
}

KUBERNETES_VERSION="${1:-1.32}"

log_info "Reading Terraform outputs from $TERRAFORM_DIR..."

cd "$TERRAFORM_DIR"

# Check if Terraform state exists
if [ ! -f "terraform.tfstate" ]; then
    echo "Error: Terraform state not found. Please run 'terraform apply' first."
    exit 1
fi

# Export Terraform outputs
export CLUSTER_NAME=$(terraform output -raw cluster_name)
export AWS_REGION=$(terraform output -raw aws_region)
export VPC_ID=$(terraform output -raw vpc_id)
export CLUSTER_ROLE_ARN=$(terraform output -raw cluster_role_arn)
export NODE_ROLE_ARN=$(terraform output -raw node_role_arn)
export KUBERNETES_VERSION=$KUBERNETES_VERSION

# Get subnet IDs as arrays
PRIVATE_SUBNETS=($(terraform output -json private_subnet_ids | jq -r '.[]'))
PUBLIC_SUBNETS=($(terraform output -json public_subnet_ids | jq -r '.[]'))

# Get AZs for the subnets
PRIVATE_SUBNET_CONFIG=""
for subnet in "${PRIVATE_SUBNETS[@]}"; do
    az=$(aws ec2 describe-subnets --subnet-ids "$subnet" --region "$AWS_REGION" --query 'Subnets[0].AvailabilityZone' --output text)
    PRIVATE_SUBNET_CONFIG="${PRIVATE_SUBNET_CONFIG}      ${az}: { id: ${subnet} }\n"
done

PUBLIC_SUBNET_CONFIG=""
for subnet in "${PUBLIC_SUBNETS[@]}"; do
    az=$(aws ec2 describe-subnets --subnet-ids "$subnet" --region "$AWS_REGION" --query 'Subnets[0].AvailabilityZone' --output text)
    PUBLIC_SUBNET_CONFIG="${PUBLIC_SUBNET_CONFIG}      ${az}: { id: ${subnet} }\n"
done

log_info "Generating eksctl configuration..."

# Generate the actual eksctl config
cat > "$SCRIPT_DIR/cluster-generated.yaml" <<EOF
# Generated eksctl Configuration
# Generated at: $(date)
# Kubernetes Version: ${KUBERNETES_VERSION}

apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: ${CLUSTER_NAME}
  region: ${AWS_REGION}
  version: "${KUBERNETES_VERSION}"

# Use Terraform-created VPC
vpc:
  id: ${VPC_ID}
  subnets:
    private:
$(echo -e "$PRIVATE_SUBNET_CONFIG")
    public:
$(echo -e "$PUBLIC_SUBNET_CONFIG")

# Use Terraform-created IAM roles
iam:
  serviceRoleARN: ${CLUSTER_ROLE_ARN}
  withOIDC: true  # Enable OIDC for Pod Identity

# Enable Pod Identity addon
addons:
  - name: eks-pod-identity-agent

# Managed node group using Terraform-created IAM role
managedNodeGroups:
  - name: ng-1
    instanceType: t3.medium
    desiredCapacity: 2
    minSize: 2
    maxSize: 4
    volumeSize: 50
    iam:
      instanceRoleARN: ${NODE_ROLE_ARN}
    privateNetworking: true
    tags:
      k8s.io/cluster-autoscaler/enabled: "true"
      k8s.io/cluster-autoscaler/${CLUSTER_NAME}: "owned"
      karpenter.sh/discovery: ${CLUSTER_NAME}

# CloudWatch logging
cloudWatch:
  clusterLogging:
    enableTypes: ["api", "audit", "authenticator", "controllerManager", "scheduler"]
EOF

log_success "Generated: $SCRIPT_DIR/cluster-generated.yaml"
log_info ""
log_info "To create the EKS cluster, run:"
log_info "  eksctl create cluster -f $SCRIPT_DIR/cluster-generated.yaml"
log_info ""
log_info "Terraform outputs:"
log_info "  Cluster Name: $CLUSTER_NAME"
log_info "  Region: $AWS_REGION"
log_info "  VPC ID: $VPC_ID"
log_info "  Kubernetes Version: $KUBERNETES_VERSION"
