#!/bin/bash
# 04-install-karpenter.sh - 安装 Karpenter controller
#
# 使用 CloudFormation 创建 IAM 资源（推荐方式）
# 参考: https://karpenter.sh/docs/getting-started/getting-started-with-karpenter/

set -euo pipefail

# 加载工具函数
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

# 默认配置
REGION="${REGION:-us-west-2}"
KARPENTER_VERSION="${KARPENTER_VERSION:-1.8.1}"
KARPENTER_NAMESPACE="${KARPENTER_NAMESPACE:-karpenter}"

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
    log_info "命名空间: $KARPENTER_NAMESPACE"

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
    log_info "步骤 1/7: 配置 kubectl..."
    configure_kubectl "$CLUSTER_NAME" "$REGION"

    # 检查 Karpenter CRD 是否已恢复
    log_info "步骤 2/7: 验证 Karpenter CRD..."
    verify_karpenter_crds

    # 创建 EC2 Spot Service Linked Role
    log_info "步骤 3/7: 创建 EC2 Spot Service Linked Role..."
    create_spot_service_linked_role

    # 使用 CloudFormation 创建 Karpenter IAM 资源
    log_info "步骤 4/7: 使用 CloudFormation 创建 Karpenter IAM 资源..."
    deploy_karpenter_cloudformation

    # 创建 Karpenter 命名空间
    log_info "步骤 5/7: 创建 Karpenter 命名空间..."
    kubectl create namespace "$KARPENTER_NAMESPACE" 2>/dev/null || log_info "命名空间已存在"

    # 配置 Pod Identity Association
    log_info "步骤 6/7: 配置 Pod Identity Association..."
    configure_pod_identity_association

    # 安装 Karpenter
    log_info "步骤 7/7: 使用 Helm 安装 Karpenter..."
    install_karpenter_helm

    # 验证安装
    log_info "验证 Karpenter 安装..."
    verify_karpenter_installation

    log_success "=========================================="
    log_success "Karpenter 安装完成!"
    log_success "=========================================="
    log_info ""
    log_info "验证 Karpenter 状态:"
    log_info "  kubectl get pods -n $KARPENTER_NAMESPACE"
    log_info "  kubectl get nodepools -n karpenter"
    log_info "  kubectl logs -n $KARPENTER_NAMESPACE -l app.kubernetes.io/name=karpenter"
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

create_spot_service_linked_role() {
    log_info "创建 EC2 Spot Service Linked Role..."

    # 尝试创建，如果已存在会返回错误（正常）
    aws iam create-service-linked-role --aws-service-name spot.amazonaws.com 2>&1 | grep -q "has been taken" && {
        log_info "EC2 Spot Service Linked Role 已存在"
    } || {
        log_success "EC2 Spot Service Linked Role 创建成功"
    }
}

deploy_karpenter_cloudformation() {
    local stack_name="Karpenter-${CLUSTER_NAME}"
    local account_id=$(aws sts get-caller-identity --query Account --output text)

    log_info "CloudFormation Stack 名称: $stack_name"

    # 检查 stack 是否已存在
    if aws cloudformation describe-stacks \
        --stack-name "$stack_name" \
        --region "$REGION" &> /dev/null; then

        local stack_status=$(aws cloudformation describe-stacks \
            --stack-name "$stack_name" \
            --region "$REGION" \
            --query 'Stacks[0].StackStatus' \
            --output text)

        log_info "CloudFormation Stack 已存在,状态: $stack_status"

        if [[ "$stack_status" == "CREATE_COMPLETE" ]] || [[ "$stack_status" == "UPDATE_COMPLETE" ]]; then
            log_success "使用现有的 CloudFormation Stack"
            return 0
        elif [[ "$stack_status" == *"IN_PROGRESS"* ]]; then
            log_info "等待 CloudFormation Stack 操作完成..."
            wait_for_cloudformation_stack "$stack_name"
            return 0
        else
            log_warning "CloudFormation Stack 状态异常: $stack_status"
            log_info "将尝试更新 Stack..."
        fi
    fi

    # 下载 CloudFormation 模板
    local template_file="/tmp/karpenter-cloudformation-${CLUSTER_NAME}.yaml"
    log_info "下载 Karpenter CloudFormation 模板..."

    curl -fsSL "https://raw.githubusercontent.com/aws/karpenter-provider-aws/v${KARPENTER_VERSION}/website/content/en/preview/getting-started/getting-started-with-karpenter/cloudformation.yaml" \
        -o "$template_file"

    if [ ! -f "$template_file" ]; then
        log_error "下载 CloudFormation 模板失败"
        exit 1
    fi

    log_success "CloudFormation 模板下载完成"

    # 部署 CloudFormation Stack
    log_info "部署 CloudFormation Stack..."
    log_info "创建的资源:"
    log_info "  - KarpenterNodeRole-${CLUSTER_NAME}"
    log_info "  - KarpenterControllerPolicy-${CLUSTER_NAME}"
    log_info "  - KarpenterNodeInstanceProfile-${CLUSTER_NAME}"

    aws cloudformation deploy \
        --stack-name "$stack_name" \
        --template-file "$template_file" \
        --capabilities CAPABILITY_NAMED_IAM \
        --parameter-overrides "ClusterName=${CLUSTER_NAME}" \
        --region "$REGION"

    log_success "CloudFormation Stack 部署完成"

    # 清理临时文件
    rm -f "$template_file"

    # 验证资源创建
    log_info "验证 IAM 资源..."

    local node_role="KarpenterNodeRole-${CLUSTER_NAME}"
    local controller_policy="KarpenterControllerPolicy-${CLUSTER_NAME}"

    if aws iam get-role --role-name "$node_role" &> /dev/null; then
        log_success "✓ Node Role: $node_role"
    else
        log_error "Node Role 未找到: $node_role"
        exit 1
    fi

    if aws iam list-policies --scope Local --query "Policies[?PolicyName=='$controller_policy']" | grep -q "$controller_policy"; then
        log_success "✓ Controller Policy: $controller_policy"
    else
        log_error "Controller Policy 未找到: $controller_policy"
        exit 1
    fi
}

wait_for_cloudformation_stack() {
    local stack_name=$1
    local timeout=600
    local elapsed=0

    log_info "等待 CloudFormation Stack 完成..."

    while [ $elapsed -lt $timeout ]; do
        local status=$(aws cloudformation describe-stacks \
            --stack-name "$stack_name" \
            --region "$REGION" \
            --query 'Stacks[0].StackStatus' \
            --output text 2>/dev/null || echo "NOT_FOUND")

        if [[ "$status" == "CREATE_COMPLETE" ]] || [[ "$status" == "UPDATE_COMPLETE" ]]; then
            log_success "CloudFormation Stack 操作完成"
            return 0
        elif [[ "$status" == *"FAILED"* ]] || [[ "$status" == *"ROLLBACK"* ]]; then
            log_error "CloudFormation Stack 操作失败: $status"
            exit 1
        fi

        log_info "  当前状态: $status (已等待 ${elapsed}s/${timeout}s)"
        sleep 10
        elapsed=$((elapsed + 10))
    done

    log_error "等待 CloudFormation Stack 超时"
    exit 1
}

configure_pod_identity_association() {
    local account_id=$(aws sts get-caller-identity --query Account --output text)
    local controller_role_arn="arn:aws:iam::${account_id}:role/KarpenterControllerRole-${CLUSTER_NAME}"

    log_info "配置 Karpenter Pod Identity Association..."
    log_info "Controller Role ARN: $controller_role_arn"

    # 检查 Controller Role 是否存在
    if ! aws iam get-role --role-name "KarpenterControllerRole-${CLUSTER_NAME}" &> /dev/null; then
        log_info "Controller Role 不存在,将自动创建..."
        create_karpenter_controller_role
    fi

    # 检查是否已存在 Pod Identity Association
    local existing=$(aws eks list-pod-identity-associations \
        --cluster-name "$CLUSTER_NAME" \
        --region "$REGION" \
        --namespace "$KARPENTER_NAMESPACE" \
        --service-account karpenter \
        --query 'associations[0].associationId' \
        --output text 2>/dev/null)

    if [ -n "$existing" ] && [ "$existing" != "None" ]; then
        log_info "Pod Identity Association 已存在: $existing"
        return 0
    fi

    # 创建 Pod Identity Association
    log_info "创建 Pod Identity Association..."
    aws eks create-pod-identity-association \
        --cluster-name "$CLUSTER_NAME" \
        --region "$REGION" \
        --namespace "$KARPENTER_NAMESPACE" \
        --service-account karpenter \
        --role-arn "$controller_role_arn"

    log_success "Pod Identity Association 创建成功"
}

create_karpenter_controller_role() {
    local role_name="KarpenterControllerRole-${CLUSTER_NAME}"
    local account_id=$(aws sts get-caller-identity --query Account --output text)
    local policy_arn="arn:aws:iam::${account_id}:policy/KarpenterControllerPolicy-${CLUSTER_NAME}"

    log_info "创建 Karpenter Controller Role (使用 Pod Identity)..."

    # 创建信任策略
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

    # 附加 CloudFormation 创建的策略
    aws iam attach-role-policy \
        --role-name "$role_name" \
        --policy-arn "$policy_arn"

    log_success "Karpenter Controller Role 创建完成"
}

install_karpenter_helm() {
    local cluster_endpoint=$(aws eks describe-cluster \
        --name "$CLUSTER_NAME" \
        --region "$REGION" \
        --query 'cluster.endpoint' \
        --output text)

    log_info "集群端点: $cluster_endpoint"
    log_info "使用 Helm 安装 Karpenter v${KARPENTER_VERSION}..."

    # Logout of helm registry to perform an unauthenticated pull against the public ECR
    helm registry logout public.ecr.aws 2>/dev/null || true

    # 安装或升级 Karpenter (使用 OCI registry)
    helm upgrade --install karpenter oci://public.ecr.aws/karpenter/karpenter \
        --namespace "$KARPENTER_NAMESPACE" \
        --create-namespace \
        --version "$KARPENTER_VERSION" \
        --set "settings.clusterName=${CLUSTER_NAME}" \
        --set "settings.clusterEndpoint=${cluster_endpoint}" \
        --set "settings.interruptionQueue=${CLUSTER_NAME}" \
        --set controller.resources.requests.cpu=1 \
        --set controller.resources.requests.memory=1Gi \
        --set controller.resources.limits.cpu=1 \
        --set controller.resources.limits.memory=1Gi \
        --wait

    log_success "Karpenter Helm chart 安装完成"
}

verify_karpenter_installation() {
    log_info "等待 Karpenter pod 就绪..."

    # 等待 Karpenter controller pod 运行
    kubectl wait --for=condition=ready pod \
        -l app.kubernetes.io/name=karpenter \
        -n "$KARPENTER_NAMESPACE" \
        --timeout=300s || log_warning "等待超时,请手动检查"

    # 显示 Karpenter pod 状态
    log_info "Karpenter Pod 状态:"
    kubectl get pods -n "$KARPENTER_NAMESPACE"

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
    kubectl logs -n "$KARPENTER_NAMESPACE" -l app.kubernetes.io/name=karpenter --tail=20 2>/dev/null || true

    log_success "Karpenter 验证完成"
}

# 执行主函数
main
