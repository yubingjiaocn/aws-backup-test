#!/bin/bash
# 04-install-karpenter.sh - 安装 Karpenter controller

set -euo pipefail

# 加载工具函数
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

# 默认配置
REGION="${REGION:-us-west-2}"
KARPENTER_VERSION="${KARPENTER_VERSION:-1.8.1}"

# 使用说明
usage() {
    cat <<EOF
使用方法: $0 CLUSTER_NAME [REGION] [KARPENTER_VERSION]

参数:
  CLUSTER_NAME              EKS 集群名称
  REGION                    AWS 区域 (默认: us-west-2)
  KARPENTER_VERSION         Karpenter 版本 (默认: 1.8.1)

示例:
  $0 eks-rollback-v132
  $0 eks-rollback-v132 us-east-1 1.8.1
EOF
    exit 1
}

# 检查参数
if [ $# -lt 1 ]; then
    log_error "缺少集群名称参数"
    usage
fi

CLUSTER_NAME="$1"
REGION="${2:-$REGION}"
KARPENTER_VERSION="${3:-$KARPENTER_VERSION}"

main() {
    log_info "=========================================="
    log_info "安装 Karpenter Controller"
    log_info "=========================================="

    check_prerequisites
    check_aws_credentials

    log_info "集群名称: $CLUSTER_NAME"
    log_info "区域: $REGION"
    log_info "Karpenter 版本: v$KARPENTER_VERSION"

    # 检查 Helm 是否安装
    if ! command -v helm &> /dev/null; then
        log_error "Helm 未安装,请先安装 Helm"
        log_info "安装方法: https://helm.sh/docs/intro/install/"
        exit 1
    fi

    # 验证集群存在
    if ! aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" &> /dev/null; then
        log_error "集群不存在: $CLUSTER_NAME"
        exit 1
    fi

    # 配置 kubectl
    log_info "步骤 1/6: 配置 kubectl..."
    configure_kubectl "$CLUSTER_NAME" "$REGION"

    # 检查 Karpenter CRD 是否已恢复
    log_info "步骤 2/6: 验证 Karpenter CRD..."
    verify_karpenter_crds

    # 创建 Karpenter IAM 角色
    log_info "步骤 3/6: 创建 Karpenter IAM 角色..."
    create_karpenter_roles

    # 创建 Karpenter 命名空间
    log_info "步骤 4/6: 创建 Karpenter 命名空间..."
    kubectl create namespace karpenter || log_info "命名空间已存在"

    # 安装 Karpenter
    log_info "步骤 5/6: 使用 Helm 安装 Karpenter..."
    install_karpenter_helm

    # 验证安装
    log_info "步骤 6/6: 验证 Karpenter 安装..."
    verify_karpenter_installation

    log_success "=========================================="
    log_success "Karpenter 安装完成!"
    log_success "=========================================="
    log_info ""
    log_info "验证 Karpenter 状态:"
    log_info "  kubectl get pods -n karpenter"
    log_info "  kubectl get nodepools -n karpenter"
    log_info "  kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter"
}

verify_karpenter_crds() {
    log_info "检查 Karpenter CRD..."

    local crds=("nodepools.karpenter.sh" "ec2nodeclasses.karpenter.k8s.aws")

    for crd in "${crds[@]}"; do
        if kubectl get crd "$crd" &> /dev/null; then
            log_success "CRD 已存在: $crd"
        else
            log_warning "CRD 未找到: $crd"
            log_info "CRD 应该已通过 AWS Backup 恢复"
            log_info "如果 CRD 缺失,Helm 安装将会创建它们"
        fi
    done
}

create_karpenter_roles() {
    local account_id=$(aws sts get-caller-identity --query Account --output text)

    # 1. Karpenter Controller IAM Role
    log_info "创建 Karpenter Controller IAM 角色..."
    create_karpenter_controller_role

    # 2. Karpenter Node IAM Role
    log_info "创建 Karpenter Node IAM 角色..."
    create_karpenter_node_role

    log_success "Karpenter IAM 角色创建完成"
}

create_karpenter_controller_role() {
    local role_name="KarpenterControllerRole-${CLUSTER_NAME}"
    local account_id=$(aws sts get-caller-identity --query Account --output text)

    # 检查角色是否已存在
    if aws iam get-role --role-name "$role_name" &> /dev/null; then
        log_info "Controller 角色已存在: $role_name"
        return 0
    fi

    log_info "创建 Karpenter Controller 角色 (使用 Pod Identity)..."

    # 创建信任策略 - 使用 Pod Identity
    cat > /tmp/karpenter-controller-trust-policy.json <<EOF
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
        --description "IAM role for Karpenter Controller on $CLUSTER_NAME (Pod Identity)"

    # 创建并附加 Karpenter 策略
    cat > /tmp/karpenter-controller-policy.json <<EOF
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

    log_success "Karpenter Controller 角色创建完成"
}

create_karpenter_node_role() {
    local role_name="KarpenterNodeRole-${CLUSTER_NAME}"
    local account_id=$(aws sts get-caller-identity --query Account --output text)

    # 检查角色是否已存在
    if aws iam get-role --role-name "$role_name" &> /dev/null; then
        log_info "Node 角色已存在: $role_name"
        return 0
    fi

    # 创建信任策略
    cat > /tmp/karpenter-node-trust-policy.json <<EOF
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
        --assume-role-policy-document file:///tmp/karpenter-node-trust-policy.json

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
        aws iam add-role-to-instance-profile \
            --instance-profile-name "$profile_name" \
            --role-name "$role_name"
    fi

    log_success "Karpenter Node 角色创建完成"
}

install_karpenter_helm() {
    local account_id=$(aws sts get-caller-identity --query Account --output text)
    local controller_role_arn="arn:aws:iam::${account_id}:role/KarpenterControllerRole-${CLUSTER_NAME}"
    local node_role="KarpenterNodeRole-${CLUSTER_NAME}"

    log_info "使用 Helm 安装 Karpenter..."

    # 创建 Pod Identity 关联
    log_info "创建 Karpenter Pod Identity 关联..."
    create_karpenter_pod_identity_association "$controller_role_arn"

    # Logout of helm registry to perform an unauthenticated pull against the public ECR
    helm registry logout public.ecr.aws || true

    # 安装或升级 Karpenter (使用 OCI registry)
    helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
        --namespace karpenter \
        --create-namespace \
        --version "$KARPENTER_VERSION" \
        --set settings.clusterName="$CLUSTER_NAME" \
        --set settings.clusterEndpoint="$(aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" --query 'cluster.endpoint' --output text)" \
        --set settings.interruptionQueue="$CLUSTER_NAME" \
        --set controller.resources.requests.cpu=1 \
        --set controller.resources.requests.memory=1Gi \
        --set controller.resources.limits.cpu=1 \
        --set controller.resources.limits.memory=1Gi \
        --wait

    log_success "Karpenter Helm chart 安装完成"
}

create_karpenter_pod_identity_association() {
    local role_arn=$1

    log_info "创建 Karpenter Pod Identity 关联..."

    # 检查是否已存在
    local existing=$(aws eks list-pod-identity-associations \
        --cluster-name "$CLUSTER_NAME" \
        --region "$REGION" \
        --namespace karpenter \
        --service-account karpenter \
        --query 'associations[0].associationId' \
        --output text 2>/dev/null)

    if [ -n "$existing" ] && [ "$existing" != "None" ]; then
        log_info "Pod Identity 关联已存在: $existing"
        return 0
    fi

    # 创建关联
    aws eks create-pod-identity-association \
        --cluster-name "$CLUSTER_NAME" \
        --region "$REGION" \
        --namespace karpenter \
        --service-account karpenter \
        --role-arn "$role_arn"

    log_success "Karpenter Pod Identity 关联创建成功"
}

verify_karpenter_installation() {
    log_info "等待 Karpenter pod 就绪..."

    # 等待 Karpenter controller pod 运行
    kubectl wait --for=condition=ready pod \
        -l app.kubernetes.io/name=karpenter \
        -n karpenter \
        --timeout=300s || log_warning "等待超时,请手动检查"

    # 显示 Karpenter pod 状态
    log_info "Karpenter Pod 状态:"
    kubectl get pods -n karpenter

    # 检查 NodePool CR
    log_info "检查 NodePool CR..."
    local nodepool_count=$(kubectl get nodepools -n karpenter --no-headers 2>/dev/null | wc -l)
    if [ "$nodepool_count" -gt 0 ]; then
        log_success "发现 $nodepool_count 个 NodePool CR (已通过 AWS Backup 恢复)"
        kubectl get nodepools -n karpenter
    else
        log_warning "未发现 NodePool CR"
        log_info "如需创建 NodePool,请应用: kubectl apply -f test-workloads/karpenter-nodepool.yaml"
    fi

    # 检查 Karpenter 日志
    log_info "Karpenter 最近日志:"
    kubectl logs -n karpenter -l app.kubernetes.io/name=karpenter --tail=20 || true

    log_success "Karpenter 验证完成"
}

# 执行主函数
main
