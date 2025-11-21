#!/bin/bash
# 03-enable-managed-addons.sh - 启用 EKS 托管 Add-on (EBS/EFS CSI Drivers)

set -euo pipefail

# 加载工具函数
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

# 默认配置
REGION="${REGION:-us-west-2}"

# 使用说明
usage() {
    cat <<EOF
使用方法: $0 CLUSTER_NAME [REGION]

参数:
  CLUSTER_NAME              EKS 集群名称
  REGION                    AWS 区域 (默认: us-west-2)

示例:
  $0 eks-rollback-v132
  $0 eks-rollback-v132 us-east-1
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

main() {
    log_info "=========================================="
    log_info "启用 EKS 托管 Add-on"
    log_info "=========================================="

    check_prerequisites
    check_aws_credentials

    log_info "集群名称: $CLUSTER_NAME"
    log_info "区域: $REGION"

    # 验证集群存在
    if ! aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" &> /dev/null; then
        log_error "集群不存在: $CLUSTER_NAME"
        exit 1
    fi

    # 启用 EBS CSI Driver
    log_info "步骤 1/2: 启用 EBS CSI Driver..."
    enable_ebs_csi_driver

    # 启用 EFS CSI Driver
    log_info "步骤 2/2: 启用 EFS CSI Driver..."
    enable_efs_csi_driver

    log_success "=========================================="
    log_success "托管 Add-on 启用完成!"
    log_success "=========================================="

    # 验证 Add-on 状态
    log_info "验证 Add-on 状态..."
    verify_addons
}

enable_ebs_csi_driver() {
    local addon_name="aws-ebs-csi-driver"

    # 检查 Add-on 是否已存在
    if aws eks describe-addon \
        --cluster-name "$CLUSTER_NAME" \
        --addon-name "$addon_name" \
        --region "$REGION" &> /dev/null; then
        log_warning "EBS CSI Driver Add-on 已存在"
        local status=$(aws eks describe-addon \
            --cluster-name "$CLUSTER_NAME" \
            --addon-name "$addon_name" \
            --region "$REGION" \
            --query 'addon.status' \
            --output text)
        log_info "当前状态: $status"

        if [ "$status" != "ACTIVE" ]; then
            log_info "等待 Add-on 变为 ACTIVE 状态..."
            wait_for_addon_active "$CLUSTER_NAME" "$addon_name" 600
        fi
        return 0
    fi

    log_info "创建 EBS CSI Driver Add-on..."

    # 创建 IAM 角色 (使用 Pod Identity)
    local service_account_role=$(create_ebs_csi_role)

    # 创建 Pod Identity 关联
    create_pod_identity_association \
        "kube-system" \
        "ebs-csi-controller-sa" \
        "$service_account_role"

    # 创建 Add-on
    aws eks create-addon \
        --cluster-name "$CLUSTER_NAME" \
        --addon-name "$addon_name" \
        --region "$REGION" \
        --resolve-conflicts OVERWRITE

    log_info "等待 Add-on 激活..."
    wait_for_addon_active "$CLUSTER_NAME" "$addon_name" 600

    # 验证 CSI driver pods 运行状态
    verify_csi_driver_pods "ebs"

    log_success "EBS CSI Driver Add-on 启用成功"
}

enable_efs_csi_driver() {
    local addon_name="aws-efs-csi-driver"

    # 检查 Add-on 是否已存在
    if aws eks describe-addon \
        --cluster-name "$CLUSTER_NAME" \
        --addon-name "$addon_name" \
        --region "$REGION" &> /dev/null; then
        log_warning "EFS CSI Driver Add-on 已存在"
        local status=$(aws eks describe-addon \
            --cluster-name "$CLUSTER_NAME" \
            --addon-name "$addon_name" \
            --region "$REGION" \
            --query 'addon.status' \
            --output text)
        log_info "当前状态: $status"

        if [ "$status" != "ACTIVE" ]; then
            log_info "等待 Add-on 变为 ACTIVE 状态..."
            wait_for_addon_active "$CLUSTER_NAME" "$addon_name" 600
        fi
        return 0
    fi

    log_info "创建 EFS CSI Driver Add-on..."

    # 创建 IAM 角色 (使用 Pod Identity)
    local service_account_role=$(create_efs_csi_role)

    # 创建 Pod Identity 关联
    create_pod_identity_association \
        "kube-system" \
        "efs-csi-controller-sa" \
        "$service_account_role"

    # 创建 Add-on
    aws eks create-addon \
        --cluster-name "$CLUSTER_NAME" \
        --addon-name "$addon_name" \
        --region "$REGION" \
        --resolve-conflicts OVERWRITE

    log_info "等待 Add-on 激活..."
    wait_for_addon_active "$CLUSTER_NAME" "$addon_name" 600

    # 验证 CSI driver pods 运行状态
    verify_csi_driver_pods "efs"

    log_success "EFS CSI Driver Add-on 启用成功"
}

create_pod_identity_association() {
    local namespace=$1
    local service_account=$2
    local role_arn=$3

    log_info "创建 Pod Identity 关联: ${namespace}/${service_account}"

    # 检查是否已存在
    local existing=$(aws eks list-pod-identity-associations \
        --cluster-name "$CLUSTER_NAME" \
        --region "$REGION" \
        --namespace "$namespace" \
        --service-account "$service_account" \
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
        --namespace "$namespace" \
        --service-account "$service_account" \
        --role-arn "$role_arn"

    log_success "Pod Identity 关联创建成功"
}

create_ebs_csi_role() {
    local role_name="AmazonEKS_EBS_CSI_DriverRole_${CLUSTER_NAME}"
    local account_id=$(aws sts get-caller-identity --query Account --output text)
    local role_arn="arn:aws:iam::${account_id}:role/${role_name}"

    # 检查角色是否已存在
    if aws iam get-role --role-name "$role_name" &> /dev/null; then
        log_info "IAM 角色已存在: $role_name"
        echo "$role_arn"
        return 0
    fi

    log_info "创建 EBS CSI Driver IAM 角色 (使用 Pod Identity)..."

    # 创建信任策略 - 使用 Pod Identity
    cat > /tmp/ebs-csi-trust-policy.json <<EOF
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
        --assume-role-policy-document file:///tmp/ebs-csi-trust-policy.json \
        --description "IAM role for EBS CSI Driver on $CLUSTER_NAME (Pod Identity)"

    # 附加策略
    aws iam attach-role-policy \
        --role-name "$role_name" \
        --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"

    log_success "EBS CSI Driver IAM 角色创建完成"
    echo "$role_arn"
}

create_efs_csi_role() {
    local role_name="AmazonEKS_EFS_CSI_DriverRole_${CLUSTER_NAME}"
    local account_id=$(aws sts get-caller-identity --query Account --output text)
    local role_arn="arn:aws:iam::${account_id}:role/${role_name}"

    # 检查角色是否已存在
    if aws iam get-role --role-name "$role_name" &> /dev/null; then
        log_info "IAM 角色已存在: $role_name"
        echo "$role_arn"
        return 0
    fi

    log_info "创建 EFS CSI Driver IAM 角色 (使用 Pod Identity)..."

    # 创建信任策略 - 使用 Pod Identity
    cat > /tmp/efs-csi-trust-policy.json <<EOF
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
        --assume-role-policy-document file:///tmp/efs-csi-trust-policy.json \
        --description "IAM role for EFS CSI Driver on $CLUSTER_NAME (Pod Identity)"

    # 附加策略
    aws iam attach-role-policy \
        --role-name "$role_name" \
        --policy-arn "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"

    log_success "EFS CSI Driver IAM 角色创建完成"
    echo "$role_arn"
}

verify_csi_driver_pods() {
    local driver_type=$1  # "ebs" or "efs"
    local timeout=300
    local elapsed=0

    log_info "验证 ${driver_type} CSI driver pods 运行状态..."

    # 根据 driver 类型设置 label selector
    local label_selector
    if [ "$driver_type" = "ebs" ]; then
        label_selector="app.kubernetes.io/name=aws-ebs-csi-driver,app.kubernetes.io/component=csi-driver"
    else
        label_selector="app.kubernetes.io/name=aws-efs-csi-driver,app.kubernetes.io/component=csi-driver"
    fi

    # 等待 controller pods 就绪
    log_info "等待 CSI controller pods 就绪..."
    while [ $elapsed -lt $timeout ]; do
        local controller_ready=$(kubectl get pods -n kube-system \
            -l "$label_selector" \
            -o json 2>/dev/null | \
            jq -r '.items[] | select(.metadata.name | contains("controller")) | select(.status.phase == "Running") | .metadata.name' | wc -l)

        if [ "$controller_ready" -ge 1 ]; then
            log_success "  ✓ CSI controller pods 运行正常 ($controller_ready 个)"
            kubectl get pods -n kube-system -l "$label_selector" | grep controller
            return 0
        fi

        log_info "  等待 CSI controller pods 启动... (已等待 ${elapsed}s/${timeout}s)"
        sleep 10
        elapsed=$((elapsed + 10))
    done

    log_error "CSI controller pods 在 ${timeout}s 内未启动"
    kubectl get pods -n kube-system -l "$label_selector"
    kubectl describe pods -n kube-system -l "$label_selector" | tail -50
    return 1
}

verify_addons() {
    log_info "验证 EBS CSI Driver..."
    local ebs_status=$(aws eks describe-addon \
        --cluster-name "$CLUSTER_NAME" \
        --addon-name aws-ebs-csi-driver \
        --region "$REGION" \
        --query 'addon.status' \
        --output text)
    log_info "  状态: $ebs_status"

    log_info "验证 EFS CSI Driver..."
    local efs_status=$(aws eks describe-addon \
        --cluster-name "$CLUSTER_NAME" \
        --addon-name aws-efs-csi-driver \
        --region "$REGION" \
        --query 'addon.status' \
        --output text)
    log_info "  状态: $efs_status"

    if [ "$ebs_status" = "ACTIVE" ] && [ "$efs_status" = "ACTIVE" ]; then
        log_success "所有 Add-on 状态正常"
    else
        log_warning "部分 Add-on 状态异常"
    fi
}

# 执行主函数
main
