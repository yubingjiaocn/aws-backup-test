#!/bin/bash
# 01-create-backup.sh - 创建 EKS 集群备份脚本

set -euo pipefail

# 加载工具函数
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

# 默认配置
REGION="${REGION:-us-west-2}"
BACKUP_VAULT="${BACKUP_VAULT:-Default}"

# 使用说明
usage() {
    cat <<EOF
使用方法: $0 CLUSTER_NAME [选项]

参数:
  CLUSTER_NAME              EKS 集群名称

选项:
  -r, --region REGION       AWS 区域 (默认: us-west-2)
  -v, --vault VAULT         备份保管库名称 (默认: Default)
  -h, --help                显示帮助信息

示例:
  $0 eks-backup-test-source
  $0 eks-backup-test-source --region us-east-1 --vault my-vault
EOF
    exit 1
}

# 检查参数
if [ $# -lt 1 ]; then
    log_error "缺少集群名称参数"
    usage
fi

CLUSTER_NAME="$1"
shift

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        -r|--region)
            REGION="$2"
            shift 2
            ;;
        -v|--vault)
            BACKUP_VAULT="$2"
            shift 2
            ;;
        -h|--help)
            usage
            ;;
        *)
            log_error "未知选项: $1"
            usage
            ;;
    esac
done

main() {
    log_info "=========================================="
    log_info "创建 EKS 集群备份"
    log_info "=========================================="

    check_prerequisites
    check_aws_credentials

    log_info "备份配置:"
    log_info "  集群名称: $CLUSTER_NAME"
    log_info "  区域: $REGION"
    log_info "  备份保管库: $BACKUP_VAULT"

    # 获取集群 ARN
    log_info "步骤 1/5: 获取集群信息..."
    local cluster_arn=$(get_cluster_arn)
    log_info "集群 ARN: $cluster_arn"

    # 确保 IAM 角色存在
    log_info "步骤 2/5: 检查 IAM 角色..."
    local backup_role=$(ensure_backup_role)
    log_info "备份 IAM 角色: $backup_role"

    # 创建备份
    log_info "步骤 3/5: 启动备份作业..."
    local backup_job_id=$(create_backup "$cluster_arn" "$backup_role")
    log_info "备份作业 ID: $backup_job_id"

    # 等待备份完成
    log_info "步骤 4/5: 等待备份完成..."
    if ! wait_for_backup_job "$backup_job_id" 3600; then
        log_error "备份失败"
        exit 1
    fi

    # 获取恢复点信息
    log_info "步骤 5/5: 获取恢复点信息..."
    get_recovery_point_info "$backup_job_id"

    log_success "=========================================="
    log_success "备份创建完成!"
    log_success "=========================================="
    log_info "备份作业 ID: $backup_job_id"
    log_info ""
    log_info "查看备份详情:"
    log_info "  aws backup describe-backup-job --backup-job-id $backup_job_id"
    log_info ""
    log_info "下一步: 运行恢复脚本"
    log_info "  ./scripts/02-restore-to-new-cluster.sh --recovery-point-arn <recovery-point-arn>"
}

get_cluster_arn() {
    local arn=$(aws eks describe-cluster \
        --name "$CLUSTER_NAME" \
        --region "$REGION" \
        --query 'cluster.arn' \
        --output text)

    if [ -z "$arn" ]; then
        log_error "无法获取集群 ARN"
        exit 1
    fi

    echo "$arn"
}

ensure_backup_role() {
    local role_name="AWSBackupDefaultServiceRole"
    local role_arn="arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/$role_name"

    # 检查角色是否存在
    if aws iam get-role --role-name "$role_name" &> /dev/null; then
        log_info "IAM 角色已存在: $role_name"
        echo "$role_arn"
        return 0
    fi

    log_info "创建 IAM 角色: $role_name"

    # 创建信任策略
    cat > /tmp/backup-trust-policy.json <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "backup.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
EOF

    # 创建角色
    aws iam create-role \
        --role-name "$role_name" \
        --assume-role-policy-document file:///tmp/backup-trust-policy.json \
        --description "Default role for AWS Backup service"

    # 附加托管策略
    aws iam attach-role-policy \
        --role-name "$role_name" \
        --policy-arn "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"

    aws iam attach-role-policy \
        --role-name "$role_name" \
        --policy-arn "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"

    # 等待角色生效
    log_info "等待 IAM 角色生效..."
    sleep 10

    log_success "IAM 角色创建完成"
    echo "$role_arn"
}

create_backup() {
    local resource_arn=$1
    local iam_role_arn=$2

    log_info "创建按需备份..."

    # 启动备份作业
    local response=$(aws backup start-backup-job \
        --backup-vault-name "$BACKUP_VAULT" \
        --resource-arn "$resource_arn" \
        --iam-role-arn "$iam_role_arn" \
        --region "$REGION" \
        --output json)

    local job_id=$(echo "$response" | jq -r '.BackupJobId')

    if [ -z "$job_id" ] || [ "$job_id" = "null" ]; then
        log_error "无法创建备份作业"
        echo "$response" | jq '.'
        exit 1
    fi

    echo "$job_id"
}

get_recovery_point_info() {
    local backup_job_id=$1

    log_info "获取恢复点信息..."

    # 获取备份作业详情
    local job_info=$(aws backup describe-backup-job \
        --backup-job-id "$backup_job_id" \
        --region "$REGION")

    local recovery_point_arn=$(echo "$job_info" | jq -r '.RecoveryPointArn')
    local backup_size=$(echo "$job_info" | jq -r '.BackupSizeInBytes')
    local creation_date=$(echo "$job_info" | jq -r '.CreationDate')
    local completion_date=$(echo "$job_info" | jq -r '.CompletionDate')

    log_success "恢复点 ARN: $recovery_point_arn"
    log_info "备份大小: $(( backup_size / 1024 / 1024 )) MB"
    log_info "创建时间: $creation_date"
    log_info "完成时间: $completion_date"

    # 获取复合恢复点的子恢复点
    log_info ""
    log_info "查询子恢复点..."

    # 等待一下让子恢复点信息生效
    sleep 5

    # 尝试获取子恢复点（针对 EKS 复合恢复点）
    local child_recovery_points=$(aws backup list-recovery-points-by-backup-vault \
        --backup-vault-name "$BACKUP_VAULT" \
        --region "$REGION" \
        --query "RecoveryPoints[?ParentRecoveryPointArn=='$recovery_point_arn']" \
        --output json 2>/dev/null || echo "[]")

    local child_count=$(echo "$child_recovery_points" | jq '. | length')

    if [ "$child_count" -gt 0 ]; then
        log_info "找到 $child_count 个子恢复点:"
        echo "$child_recovery_points" | jq -r '.[] | "  - \(.ResourceType): \(.RecoveryPointArn)"'
    else
        log_info "这是一个独立恢复点（非复合恢复点）"
    fi

    # 保存恢复点信息到文件
    local output_dir="/home/ubuntu/aws-backup-test/results"
    mkdir -p "$output_dir"

    local output_file="$output_dir/backup-$(date +%Y%m%d-%H%M%S).json"
    echo "$job_info" > "$output_file"
    log_info "备份详情已保存到: $output_file"

    # 输出恢复命令示例
    echo ""
    log_info "=========================================="
    log_info "恢复命令示例:"
    log_info "=========================================="
    echo ""
    echo "# 恢复到新集群（版本回滚）:"
    echo "./scripts/02-restore-to-new-cluster.sh \\"
    echo "  --recovery-point-arn \"$recovery_point_arn\" \\"
    echo "  --cluster-name eks-rollback-test \\"
    echo "  --eks-version 1.32"
    echo ""
    echo "# 恢复到现有集群:"
    echo "./scripts/02-restore-to-existing-cluster.sh \\"
    echo "  --recovery-point-arn \"$recovery_point_arn\" \\"
    echo "  --cluster-name $CLUSTER_NAME"
    echo ""
}

# 执行主函数
main
