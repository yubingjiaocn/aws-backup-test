#!/bin/bash
# 99-cleanup-all.sh - 清理所有测试资源
#
# 此脚本会按正确顺序删除所有测试创建的资源
# 警告: 这是破坏性操作，请确认后再运行！

set -euo pipefail

# 加载工具函数
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

# 默认配置
REGION="${REGION:-us-west-2}"
DRY_RUN="${DRY_RUN:-false}"

# 集群名称列表
CLUSTERS=()

# 使用说明
usage() {
    cat <<EOF
使用方法: $0 [选项] CLUSTER_NAME [CLUSTER_NAME2 ...]

选项:
  --region REGION       AWS 区域 (默认: us-west-2)
  --dry-run             只显示将要删除的资源，不实际删除
  --confirm             跳过确认提示（危险！）
  -h, --help            显示帮助信息

示例:
  # 清理单个集群
  $0 my-test-cluster

  # 清理多个集群（包括恢复的集群）
  $0 my-test-cluster eks-rollback-v132

  # 预览将要删除的资源
  $0 --dry-run my-test-cluster

  # 自动确认（用于脚本）
  $0 --confirm my-test-cluster
EOF
    exit 1
}

# 解析参数
SKIP_CONFIRM=false
while [[ $# -gt 0 ]]; do
    case $1 in
        --region)
            REGION="$2"
            shift 2
            ;;
        --dry-run)
            DRY_RUN=true
            shift
            ;;
        --confirm)
            SKIP_CONFIRM=true
            shift
            ;;
        -h|--help)
            usage
            ;;
        *)
            CLUSTERS+=("$1")
            shift
            ;;
    esac
done

if [ ${#CLUSTERS[@]} -eq 0 ]; then
    log_error "至少需要指定一个集群名称"
    usage
fi

main() {
    log_info "=========================================="
    log_info "AWS Backup EKS 测试资源清理脚本"
    log_info "=========================================="

    check_prerequisites
    check_aws_credentials

    local account_id=$(aws sts get-caller-identity --query Account --output text)

    log_info "AWS 账户: $account_id"
    log_info "区域: $REGION"
    log_info "将要清理的集群: ${CLUSTERS[*]}"
    log_info "Dry Run 模式: $DRY_RUN"

    # 确认提示
    if [ "$SKIP_CONFIRM" = false ] && [ "$DRY_RUN" = false ]; then
        echo ""
        log_warning "⚠️  警告：这将删除以下所有资源："
        echo ""
        echo "  1. Karpenter 创建的 EC2 实例和 Launch Templates"
        echo "  2. Karpenter CloudFormation Stacks 和 IAM 资源"
        echo "  3. CSI Driver 的 IAM 角色和 Pod Identity Associations"
        echo "  4. EKS 集群和所有相关资源"
        echo "  5. Terraform 创建的 VPC、EFS 等基础设施"
        echo ""
        read -p "确定要继续吗? (输入 'yes' 确认): " confirmation
        if [ "$confirmation" != "yes" ]; then
            log_info "已取消"
            exit 0
        fi
    fi

    # 步骤 1: 清理每个集群的 Karpenter 资源
    for cluster_name in "${CLUSTERS[@]}"; do
        log_info "步骤 1: 清理集群 $cluster_name 的 Karpenter 资源..."
        cleanup_karpenter_resources "$cluster_name"
    done

    # 步骤 2: 清理 CSI Driver IAM 资源
    for cluster_name in "${CLUSTERS[@]}"; do
        log_info "步骤 2: 清理集群 $cluster_name 的 CSI Driver IAM 资源..."
        cleanup_csi_driver_resources "$cluster_name"
    done

    # 步骤 3: 删除 EKS 集群
    for cluster_name in "${CLUSTERS[@]}"; do
        log_info "步骤 3: 删除 EKS 集群 $cluster_name..."
        delete_eks_cluster "$cluster_name"
    done

    # 步骤 4: 清理 Terraform 资源
    log_info "步骤 4: 清理 Terraform 资源..."
    cleanup_terraform_resources

    # 步骤 5: 列出 AWS Backup 备份点
    log_info "步骤 5: 检查 AWS Backup 备份点..."
    list_backup_recovery_points

    log_success "=========================================="
    log_success "清理完成!"
    log_success "=========================================="
    log_info ""
    log_info "建议: 检查 AWS 控制台确保所有资源已删除"
    log_info "  - CloudFormation Stacks"
    log_info "  - IAM 角色和策略"
    log_info "  - EC2 Launch Templates"
    log_info "  - EKS Pod Identity Associations"
}

cleanup_karpenter_resources() {
    local cluster_name=$1
    local stack_name="Karpenter-${cluster_name}"

    log_info "清理集群 $cluster_name 的 Karpenter 资源..."

    # 1. 删除 Karpenter 创建的 Launch Templates
    log_info "  1/4: 删除 Launch Templates..."
    delete_karpenter_launch_templates "$cluster_name"

    # 2. 删除 Karpenter Pod Identity Associations
    log_info "  2/4: 删除 Karpenter Pod Identity Association..."
    delete_pod_identity_association "$cluster_name" "karpenter" "karpenter"

    # 3. 删除单独创建的 KarpenterControllerRole (如果存在)
    log_info "  3/4: 删除 KarpenterControllerRole (如果存在)..."
    delete_iam_role "KarpenterControllerRole-${cluster_name}"

    # 4. 删除 CloudFormation Stack
    log_info "  4/4: 删除 CloudFormation Stack..."
    delete_cloudformation_stack "$stack_name"
}

delete_karpenter_launch_templates() {
    local cluster_name=$1

    log_info "查找 Karpenter 创建的 Launch Templates..."

    local templates=$(aws ec2 describe-launch-templates \
        --region "$REGION" \
        --filters "Name=tag:karpenter.k8s.aws/cluster,Values=${cluster_name}" \
        --query 'LaunchTemplates[].LaunchTemplateName' \
        --output text 2>/dev/null || true)

    if [ -z "$templates" ]; then
        log_info "未找到 Launch Templates"
        return 0
    fi

    log_info "找到 Launch Templates: $templates"

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] 将删除 Launch Templates: $templates"
        return 0
    fi

    for template in $templates; do
        log_info "删除 Launch Template: $template"
        aws ec2 delete-launch-template \
            --launch-template-name "$template" \
            --region "$REGION" || log_warning "删除失败: $template"
    done

    log_success "Launch Templates 删除完成"
}

delete_pod_identity_association() {
    local cluster_name=$1
    local namespace=$2
    local service_account=$3

    # 检查集群是否存在
    if ! aws eks describe-cluster --name "$cluster_name" --region "$REGION" &> /dev/null; then
        log_info "集群不存在，跳过 Pod Identity Association 删除"
        return 0
    fi

    log_info "删除 Pod Identity Association: ${namespace}/${service_account}"

    local association_id=$(aws eks list-pod-identity-associations \
        --cluster-name "$cluster_name" \
        --region "$REGION" \
        --namespace "$namespace" \
        --service-account "$service_account" \
        --query 'associations[0].associationId' \
        --output text 2>/dev/null || echo "")

    if [ -z "$association_id" ] || [ "$association_id" = "None" ]; then
        log_info "Pod Identity Association 不存在"
        return 0
    fi

    log_info "找到 Association ID: $association_id"

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] 将删除 Pod Identity Association: $association_id"
        return 0
    fi

    aws eks delete-pod-identity-association \
        --cluster-name "$cluster_name" \
        --region "$REGION" \
        --association-id "$association_id" || log_warning "删除失败"

    log_success "Pod Identity Association 删除完成"
}

delete_iam_role() {
    local role_name=$1

    if ! aws iam get-role --role-name "$role_name" &> /dev/null; then
        log_info "IAM 角色不存在: $role_name"
        return 0
    fi

    log_info "找到 IAM 角色: $role_name"

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] 将删除 IAM 角色: $role_name"
        return 0
    fi

    # 先删除附加的策略
    log_info "分离附加的托管策略..."
    local attached_policies=$(aws iam list-attached-role-policies \
        --role-name "$role_name" \
        --query 'AttachedPolicies[].PolicyArn' \
        --output text 2>/dev/null || true)

    for policy_arn in $attached_policies; do
        log_info "  分离策略: $policy_arn"
        aws iam detach-role-policy \
            --role-name "$role_name" \
            --policy-arn "$policy_arn" || log_warning "分离失败: $policy_arn"
    done

    # 删除内联策略
    log_info "删除内联策略..."
    local inline_policies=$(aws iam list-role-policies \
        --role-name "$role_name" \
        --query 'PolicyNames[]' \
        --output text 2>/dev/null || true)

    for policy_name in $inline_policies; do
        log_info "  删除策略: $policy_name"
        aws iam delete-role-policy \
            --role-name "$role_name" \
            --policy-name "$policy_name" || log_warning "删除失败: $policy_name"
    done

    # 删除实例配置文件关联 (如果存在)
    local instance_profiles=$(aws iam list-instance-profiles-for-role \
        --role-name "$role_name" \
        --query 'InstanceProfiles[].InstanceProfileName' \
        --output text 2>/dev/null || true)

    for profile_name in $instance_profiles; do
        log_info "  从实例配置文件移除: $profile_name"
        aws iam remove-role-from-instance-profile \
            --instance-profile-name "$profile_name" \
            --role-name "$role_name" || log_warning "移除失败: $profile_name"
    done

    # 删除角色
    log_info "删除 IAM 角色..."
    aws iam delete-role --role-name "$role_name" || log_warning "删除失败"

    log_success "IAM 角色删除完成: $role_name"
}

delete_cloudformation_stack() {
    local stack_name=$1

    if ! aws cloudformation describe-stacks \
        --stack-name "$stack_name" \
        --region "$REGION" &> /dev/null; then
        log_info "CloudFormation Stack 不存在: $stack_name"
        return 0
    fi

    log_info "找到 CloudFormation Stack: $stack_name"

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] 将删除 CloudFormation Stack: $stack_name"
        return 0
    fi

    log_info "删除 CloudFormation Stack..."
    aws cloudformation delete-stack \
        --stack-name "$stack_name" \
        --region "$REGION"

    log_info "等待 Stack 删除完成..."
    aws cloudformation wait stack-delete-complete \
        --stack-name "$stack_name" \
        --region "$REGION" 2>/dev/null || log_warning "等待超时或失败"

    log_success "CloudFormation Stack 删除完成"
}

cleanup_csi_driver_resources() {
    local cluster_name=$1

    log_info "清理集群 $cluster_name 的 CSI Driver 资源..."

    # 删除 EBS CSI Driver Pod Identity Association
    log_info "  1/4: 删除 EBS CSI Driver Pod Identity Association..."
    delete_pod_identity_association "$cluster_name" "kube-system" "ebs-csi-controller-sa"

    # 删除 EFS CSI Driver Pod Identity Association
    log_info "  2/4: 删除 EFS CSI Driver Pod Identity Association..."
    delete_pod_identity_association "$cluster_name" "kube-system" "efs-csi-controller-sa"

    # 删除 EBS CSI Driver IAM 角色
    log_info "  3/4: 删除 EBS CSI Driver IAM 角色..."
    delete_iam_role "AmazonEKS_EBS_CSI_DriverRole_${cluster_name}"

    # 删除 EFS CSI Driver IAM 角色
    log_info "  4/4: 删除 EFS CSI Driver IAM 角色..."
    delete_iam_role "AmazonEKS_EFS_CSI_DriverRole_${cluster_name}"

    log_success "CSI Driver 资源清理完成"
}

delete_eks_cluster() {
    local cluster_name=$1

    if ! aws eks describe-cluster --name "$cluster_name" --region "$REGION" &> /dev/null; then
        log_info "EKS 集群不存在: $cluster_name"
        return 0
    fi

    log_info "找到 EKS 集群: $cluster_name"

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] 将删除 EKS 集群: $cluster_name"
        return 0
    fi

    log_info "删除 EKS 集群 (这可能需要 10-15 分钟)..."
    log_info "eksctl 会自动清理:"
    log_info "  - Managed Node Groups"
    log_info "  - OIDC Provider"
    log_info "  - EKS Addons 创建的 IAM 角色和 Pod Identity Associations"

    eksctl delete cluster \
        --name "$cluster_name" \
        --region "$REGION" \
        --wait || log_warning "删除失败或超时"

    log_success "EKS 集群删除完成"
}

cleanup_terraform_resources() {
    local terraform_dir="${SCRIPT_DIR}/../terraform"

    if [ ! -f "$terraform_dir/terraform.tfstate" ]; then
        log_info "Terraform state 不存在，跳过"
        return 0
    fi

    log_info "找到 Terraform 资源"

    if [ "$DRY_RUN" = true ]; then
        log_info "[DRY RUN] 将销毁 Terraform 资源:"
        cd "$terraform_dir"
        terraform plan -destroy || true
        return 0
    fi

    log_info "销毁 Terraform 资源..."
    cd "$terraform_dir"
    terraform destroy -auto-approve || log_warning "销毁失败"

    log_success "Terraform 资源销毁完成"
}

list_backup_recovery_points() {
    log_info "检查 AWS Backup 备份点..."

    # Try to get backup vault from Terraform output, fallback to "Default"
    local backup_vault=$(cd "${SCRIPT_DIR}/../terraform" && terraform output -raw backup_vault_name 2>/dev/null || echo "Default")
    log_info "备份保管库: $backup_vault"

    local recovery_points=$(aws backup list-recovery-points-by-backup-vault \
        --backup-vault-name "$backup_vault" \
        --region "$REGION" \
        --query 'RecoveryPoints[].RecoveryPointArn' \
        --output text 2>/dev/null || true)

    if [ -z "$recovery_points" ]; then
        log_info "未找到备份点"
        return 0
    fi

    log_warning "找到以下备份点:"
    echo "$recovery_points" | tr '\t' '\n'

    if [ "$DRY_RUN" = false ]; then
        echo ""
        log_info "如需删除备份点，请手动运行:"
        echo "$recovery_points" | tr '\t' '\n' | while read -r arn; do
            echo "  aws backup delete-recovery-point --backup-vault-name $backup_vault --recovery-point-arn \"$arn\" --region $REGION"
        done
    fi
}

# 执行主函数
main
