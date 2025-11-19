#!/bin/bash
# create-iam-roles.sh - 创建恢复所需的 IAM 角色
# 这个脚本创建 EKS 集群恢复所需的 IAM 角色

set -euo pipefail

# 加载工具函数
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

# 使用说明
usage() {
    cat <<EOF
使用方法: $0 [CLUSTER_NAME]

参数:
  CLUSTER_NAME    集群名称 (可选,用于命名角色)

此脚本创建以下 IAM 角色:
  - eksClusterRole: EKS 集群角色
  - eksNodeRole: EKS 节点角色
  - KarpenterControllerRole-<CLUSTER_NAME>: Karpenter 控制器角色
  - KarpenterNodeRole-<CLUSTER_NAME>: Karpenter 节点角色

示例:
  $0
  $0 my-cluster
EOF
    exit 1
}

CLUSTER_NAME="${1:-eks-backup-test}"

main() {
    log_info "=========================================="
    log_info "创建 IAM 角色"
    log_info "=========================================="

    check_prerequisites
    check_aws_credentials

    log_info "集群名称: $CLUSTER_NAME"

    # 获取账户 ID
    local account_id=$(aws sts get-caller-identity --query Account --output text)
    log_info "AWS 账户: $account_id"

    # 创建 EKS 集群角色
    log_info "步骤 1/4: 创建 EKS 集群角色..."
    create_eks_cluster_role

    # 创建 EKS 节点角色
    log_info "步骤 2/4: 创建 EKS 节点角色..."
    create_eks_node_role

    # 创建 Karpenter Controller 角色
    log_info "步骤 3/4: 创建 Karpenter Controller 角色..."
    create_karpenter_controller_role_standalone

    # 创建 Karpenter Node 角色
    log_info "步骤 4/4: 创建 Karpenter Node 角色..."
    create_karpenter_node_role_standalone

    log_success "=========================================="
    log_success "所有 IAM 角色创建完成!"
    log_success "=========================================="
    log_info ""
    log_info "创建的角色:"
    log_info "  - eksClusterRole"
    log_info "  - eksNodeRole"
    log_info "  - KarpenterControllerRole-${CLUSTER_NAME}"
    log_info "  - KarpenterNodeRole-${CLUSTER_NAME}"
}

create_eks_cluster_role() {
    local role_name="eksClusterRole"
    local account_id=$(aws sts get-caller-identity --query Account --output text)
    local role_arn="arn:aws:iam::${account_id}:role/${role_name}"

    # 检查角色是否已存在
    if aws iam get-role --role-name "$role_name" &> /dev/null; then
        log_info "角色已存在: $role_name"
        echo "$role_arn"
        return 0
    fi

    log_info "创建 EKS 集群角色: $role_name"

    # 创建信任策略
    cat > /tmp/eks-cluster-trust-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "eks.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

    # 创建角色
    aws iam create-role \
        --role-name "$role_name" \
        --assume-role-policy-document file:///tmp/eks-cluster-trust-policy.json \
        --description "IAM role for EKS cluster"

    # 附加必需的托管策略
    aws iam attach-role-policy \
        --role-name "$role_name" \
        --policy-arn "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"

    # 等待角色生效
    sleep 10

    log_success "EKS 集群角色创建完成: $role_arn"
    echo "$role_arn"
}

create_eks_node_role() {
    local role_name="eksNodeRole"
    local account_id=$(aws sts get-caller-identity --query Account --output text)
    local role_arn="arn:aws:iam::${account_id}:role/${role_name}"

    # 检查角色是否已存在
    if aws iam get-role --role-name "$role_name" &> /dev/null; then
        log_info "角色已存在: $role_name"
        echo "$role_arn"
        return 0
    fi

    log_info "创建 EKS 节点角色: $role_name"

    # 创建信任策略
    cat > /tmp/eks-node-trust-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

    # 创建角色
    aws iam create-role \
        --role-name "$role_name" \
        --assume-role-policy-document file:///tmp/eks-node-trust-policy.json \
        --description "IAM role for EKS worker nodes"

    # 附加必需的托管策略
    aws iam attach-role-policy \
        --role-name "$role_name" \
        --policy-arn "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"

    aws iam attach-role-policy \
        --role-name "$role_name" \
        --policy-arn "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"

    aws iam attach-role-policy \
        --role-name "$role_name" \
        --policy-arn "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"

    # 创建实例配置文件
    local profile_name="eksNodeInstanceProfile"
    if ! aws iam get-instance-profile --instance-profile-name "$profile_name" &> /dev/null; then
        aws iam create-instance-profile --instance-profile-name "$profile_name"
        sleep 5
        aws iam add-role-to-instance-profile \
            --instance-profile-name "$profile_name" \
            --role-name "$role_name"
    fi

    # 等待角色生效
    sleep 10

    log_success "EKS 节点角色创建完成: $role_arn"
    echo "$role_arn"
}

create_karpenter_controller_role_standalone() {
    local role_name="KarpenterControllerRole-${CLUSTER_NAME}"
    local account_id=$(aws sts get-caller-identity --query Account --output text)
    local role_arn="arn:aws:iam::${account_id}:role/${role_name}"

    # 检查角色是否已存在
    if aws iam get-role --role-name "$role_name" &> /dev/null; then
        log_info "角色已存在: $role_name"
        return 0
    fi

    log_info "创建 Karpenter Controller 角色: $role_name (使用 Pod Identity)"

    # 使用 Pod Identity 信任策略
    cat > /tmp/karpenter-controller-trust-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "pods.eks.amazonaws.com"
      },
      "Action": [
        "sts:AssumeRole",
        "sts:TagSession"
      ]
    }
  ]
}
EOF

    # 创建角色
    aws iam create-role \
        --role-name "$role_name" \
        --assume-role-policy-document file:///tmp/karpenter-controller-trust-policy.json \
        --description "IAM role for Karpenter Controller on ${CLUSTER_NAME} (Pod Identity)"

    # 创建并附加 Karpenter 策略
    cat > /tmp/karpenter-controller-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "ec2:CreateFleet",
        "ec2:CreateLaunchTemplate",
        "ec2:CreateTags",
        "ec2:DescribeAvailabilityZones",
        "ec2:DescribeImages",
        "ec2:DescribeInstances",
        "ec2:DescribeInstanceTypeOfferings",
        "ec2:DescribeInstanceTypes",
        "ec2:DescribeLaunchTemplates",
        "ec2:DescribeSecurityGroups",
        "ec2:DescribeSpotPriceHistory",
        "ec2:DescribeSubnets",
        "ec2:DeleteLaunchTemplate",
        "ec2:RunInstances",
        "ec2:TerminateInstances",
        "iam:PassRole",
        "eks:DescribeCluster",
        "ssm:GetParameter",
        "pricing:GetProducts"
      ],
      "Resource": "*"
    }
  ]
}
EOF

    aws iam put-role-policy \
        --role-name "$role_name" \
        --policy-name "KarpenterControllerPolicy" \
        --policy-document file:///tmp/karpenter-controller-policy.json

    log_success "Karpenter Controller 角色创建完成 (Pod Identity 就绪)"
}

create_karpenter_node_role_standalone() {
    local role_name="KarpenterNodeRole-${CLUSTER_NAME}"
    local account_id=$(aws sts get-caller-identity --query Account --output text)
    local role_arn="arn:aws:iam::${account_id}:role/${role_name}"

    # 检查角色是否已存在
    if aws iam get-role --role-name "$role_name" &> /dev/null; then
        log_info "角色已存在: $role_name"
        return 0
    fi

    log_info "创建 Karpenter Node 角色: $role_name"

    # 创建信任策略
    cat > /tmp/karpenter-node-trust-policy.json <<'EOF'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "ec2.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

    # 创建角色
    aws iam create-role \
        --role-name "$role_name" \
        --assume-role-policy-document file:///tmp/karpenter-node-trust-policy.json \
        --description "IAM role for Karpenter nodes on ${CLUSTER_NAME}"

    # 附加必需的托管策略
    aws iam attach-role-policy \
        --role-name "$role_name" \
        --policy-arn "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy"

    aws iam attach-role-policy \
        --role-name "$role_name" \
        --policy-arn "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy"

    aws iam attach-role-policy \
        --role-name "$role_name" \
        --policy-arn "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly"

    aws iam attach-role-policy \
        --role-name "$role_name" \
        --policy-arn "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"

    # 创建实例配置文件
    local profile_name="KarpenterNodeInstanceProfile-${CLUSTER_NAME}"
    if ! aws iam get-instance-profile --instance-profile-name "$profile_name" &> /dev/null; then
        aws iam create-instance-profile --instance-profile-name "$profile_name"
        sleep 5
        aws iam add-role-to-instance-profile \
            --instance-profile-name "$profile_name" \
            --role-name "$role_name"
    fi

    log_success "Karpenter Node 角色创建完成: $role_arn"
}

# 执行主函数
main
