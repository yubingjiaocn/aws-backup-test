#!/bin/bash
# 02-restore-to-new-cluster.sh - 恢复 EKS 集群到新集群
# 用于版本回滚场景

set -euo pipefail

# 加载工具函数
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

# 默认配置
REGION="${REGION:-us-west-2}"
SKIP_ADDONS=false

# 使用说明
usage() {
    cat <<EOF
使用方法: $0 [选项]

选项:
  --recovery-point-arn ARN  恢复点 ARN (必需)
  --cluster-name NAME       新集群名称 (必需)
  --eks-version VERSION     EKS 版本 (必需,例如: 1.32)
  -r, --region REGION       AWS 区域 (默认: us-west-2)
  --skip-addons             跳过托管 Add-on 启用
  -h, --help                显示帮助信息

示例:
  $0 \\
    --recovery-point-arn arn:aws:backup:us-west-2:123456789012:recovery-point:xxx \\
    --cluster-name eks-rollback-v132 \\
    --eks-version 1.32

  # 恢复到新版本（升级测试）
  $0 \\
    --recovery-point-arn arn:aws:backup:us-west-2:123456789012:recovery-point:xxx \\
    --cluster-name eks-upgrade-v134 \\
    --eks-version 1.34
EOF
    exit 1
}

# 解析命令行参数
RECOVERY_POINT_ARN=""
NEW_CLUSTER_NAME=""
EKS_VERSION=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --recovery-point-arn)
            RECOVERY_POINT_ARN="$2"
            shift 2
            ;;
        --cluster-name)
            NEW_CLUSTER_NAME="$2"
            shift 2
            ;;
        --eks-version)
            EKS_VERSION="$2"
            shift 2
            ;;
        -r|--region)
            REGION="$2"
            shift 2
            ;;
        --skip-addons)
            SKIP_ADDONS=true
            shift
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

# 验证必需参数
if [ -z "$RECOVERY_POINT_ARN" ] || [ -z "$NEW_CLUSTER_NAME" ] || [ -z "$EKS_VERSION" ]; then
    log_error "缺少必需参数"
    usage
fi

main() {
    log_info "=========================================="
    log_info "恢复 EKS 集群到新集群"
    log_info "=========================================="

    check_prerequisites
    check_aws_credentials

    log_info "恢复配置:"
    log_info "  恢复点 ARN: $RECOVERY_POINT_ARN"
    log_info "  新集群名称: $NEW_CLUSTER_NAME"
    log_info "  EKS 版本: $EKS_VERSION"
    log_info "  区域: $REGION"

    # 准备 RTO 测量
    local rto_file="/home/ubuntu/aws-backup-test/results/rto-$(date +%Y%m%d-%H%M%S).csv"
    mkdir -p "$(dirname "$rto_file")"
    echo "timestamp,event" > "$rto_file"
    record_timestamp "恢复作业开始" "$rto_file"

    # 检查集群是否已存在
    if aws eks describe-cluster --name "$NEW_CLUSTER_NAME" --region "$REGION" &> /dev/null; then
        log_error "集群 $NEW_CLUSTER_NAME 已存在,请使用不同的名称"
        exit 1
    fi

    # 获取源集群信息
    log_info "步骤 1/7: 获取源集群配置..."
    local source_config=$(get_source_cluster_config)

    # 准备恢复参数
    log_info "步骤 2/7: 准备恢复参数..."
    local restore_metadata=$(prepare_restore_metadata "$source_config")

    # 确保 IAM 角色存在
    log_info "步骤 3/7: 检查 IAM 角色..."
    local restore_role=$(ensure_restore_role)

    # 启动恢复作业
    log_info "步骤 4/7: 启动恢复作业..."
    local restore_job_id=$(start_restore_job "$restore_metadata" "$restore_role")
    log_info "恢复作业 ID: $restore_job_id"
    record_timestamp "恢复作业已启动" "$rto_file"

    # 等待恢复完成
    log_info "步骤 5/7: 等待恢复完成 (这可能需要 15-30 分钟)..."
    if ! wait_for_restore_job "$restore_job_id" 3600; then
        log_error "恢复失败"
        exit 1
    fi
    record_timestamp "恢复作业完成" "$rto_file"

    # 配置 kubectl
    log_info "步骤 6/7: 配置 kubectl 访问新集群..."
    sleep 30  # 等待集群完全就绪
    configure_kubectl "$NEW_CLUSTER_NAME" "$REGION"
    record_timestamp "kubectl 配置完成" "$rto_file"

    # 启用托管 Add-on
    if [ "$SKIP_ADDONS" = false ]; then
        log_info "步骤 7/7: 启用托管 Add-on..."
        "$SCRIPT_DIR/03-enable-managed-addons.sh" "$NEW_CLUSTER_NAME" "$REGION"
        record_timestamp "托管 Add-on 就绪" "$rto_file"
    else
        log_warning "跳过托管 Add-on 启用"
    fi

    # 生成报告
    generate_restore_report "$restore_job_id" "$rto_file"

    log_success "=========================================="
    log_success "恢复完成!"
    log_success "=========================================="
    log_info "新集群名称: $NEW_CLUSTER_NAME"
    log_info "恢复作业 ID: $restore_job_id"
    log_info "RTO 数据: $rto_file"
    log_info ""
    log_info "下一步:"
    log_info "  1. 验证恢复: ./scripts/05-verify-restore.sh $NEW_CLUSTER_NAME"
    log_info "  2. 安装 Karpenter: ./scripts/04-install-karpenter.sh $NEW_CLUSTER_NAME"
}

get_source_cluster_config() {
    log_info "从恢复点获取源集群配置..."

    # 从恢复点 ARN 提取信息
    # 格式: arn:aws:backup:region:account:recovery-point:resource-id
    local resource_id=$(echo "$RECOVERY_POINT_ARN" | awk -F':' '{print $NF}')

    # 获取恢复点详情
    local recovery_point=$(aws backup describe-recovery-point \
        --recovery-point-arn "$RECOVERY_POINT_ARN" \
        --region "$REGION" \
        --output json)

    echo "$recovery_point"
}

prepare_restore_metadata() {
    local source_config=$1

    log_info "准备恢复元数据..."

    # 获取当前账户信息
    local account_id=$(aws sts get-caller-identity --query Account --output text)

    # 准备 IAM 角色 ARN
    local cluster_role_arn="arn:aws:iam::${account_id}:role/eksClusterRole"
    local node_role_arn="arn:aws:iam::${account_id}:role/eksNodeRole"

    # 获取默认 VPC 和子网（或使用现有）
    log_info "获取 VPC 和子网配置..."
    local vpc_config=$(get_vpc_config)
    local vpc_id=$(echo "$vpc_config" | jq -r '.vpcId')
    local subnet_ids=$(echo "$vpc_config" | jq -r '.subnetIds | join(",")')

    # 构建恢复元数据
    cat <<EOF
{
  "clusterName": "$NEW_CLUSTER_NAME",
  "newCluster": true,
  "eksClusterVersion": "$EKS_VERSION",
  "clusterRole": "$cluster_role_arn",
  "clusterVpcConfig": "{\"vpcId\":\"$vpc_id\",\"subnetIds\":[${subnet_ids}]}"
}
EOF
}

get_vpc_config() {
    # 获取默认 VPC
    local vpc_id=$(aws ec2 describe-vpcs \
        --filters "Name=is-default,Values=true" \
        --region "$REGION" \
        --query 'Vpcs[0].VpcId' \
        --output text)

    if [ -z "$vpc_id" ] || [ "$vpc_id" = "None" ]; then
        log_error "未找到默认 VPC"
        log_info "请手动指定 VPC 配置或创建 VPC"
        exit 1
    fi

    # 获取子网
    local subnets=$(aws ec2 describe-subnets \
        --filters "Name=vpc-id,Values=$vpc_id" \
        --region "$REGION" \
        --query 'Subnets[*].SubnetId' \
        --output json)

    local subnet_count=$(echo "$subnets" | jq '. | length')
    if [ "$subnet_count" -lt 2 ]; then
        log_error "VPC $vpc_id 的子网数量不足（至少需要 2 个）"
        exit 1
    fi

    # 取前 3 个子网
    local subnet_ids=$(echo "$subnets" | jq -r '.[0:3] | map("\"" + . + "\"") | join(",")')

    cat <<EOF
{
  "vpcId": "$vpc_id",
  "subnetIds": [$subnet_ids]
}
EOF
}

ensure_restore_role() {
    local role_name="AWSBackupDefaultServiceRole"
    local role_arn="arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/$role_name"

    # 检查角色是否存在
    if aws iam get-role --role-name "$role_name" &> /dev/null; then
        log_info "IAM 角色已存在: $role_name"
        echo "$role_arn"
        return 0
    fi

    log_error "IAM 角色不存在: $role_name"
    log_info "请先运行备份脚本或手动创建角色"
    exit 1
}

start_restore_job() {
    local metadata=$1
    local iam_role_arn=$2

    log_info "启动恢复作业..."

    # 启动恢复作业
    local response=$(aws backup start-restore-job \
        --recovery-point-arn "$RECOVERY_POINT_ARN" \
        --iam-role-arn "$iam_role_arn" \
        --metadata "$metadata" \
        --resource-type EKS \
        --region "$REGION" \
        --output json 2>&1)

    # 检查是否成功
    if echo "$response" | jq -e '.RestoreJobId' > /dev/null 2>&1; then
        local job_id=$(echo "$response" | jq -r '.RestoreJobId')
        log_success "恢复作业已启动: $job_id"
        echo "$job_id"
    else
        log_error "启动恢复作业失败:"
        echo "$response"
        exit 1
    fi
}

generate_restore_report() {
    local restore_job_id=$1
    local rto_file=$2

    log_info "生成恢复报告..."

    # 获取恢复作业详情
    local job_info=$(aws backup describe-restore-job \
        --restore-job-id "$restore_job_id" \
        --region "$REGION" \
        --output json)

    local created_resource=$(echo "$job_info" | jq -r '.CreatedResourceArn')
    local creation_date=$(echo "$job_info" | jq -r '.CreationDate')
    local completion_date=$(echo "$job_info" | jq -r '.CompletionDate')

    # 计算 RTO
    local start_ts=$(date -d "$creation_date" +%s 2>/dev/null || echo "0")
    local end_ts=$(date -d "$completion_date" +%s 2>/dev/null || echo "0")
    local rto_seconds=$((end_ts - start_ts))
    local rto_minutes=$((rto_seconds / 60))

    log_info "=========================================="
    log_info "恢复统计:"
    log_info "=========================================="
    log_info "创建的资源: $created_resource"
    log_info "开始时间: $creation_date"
    log_info "完成时间: $completion_date"
    log_info "RTO: ${rto_minutes} 分钟 (${rto_seconds} 秒)"
    log_info "=========================================="

    # 保存报告
    local report_dir=$(generate_test_report "restore-to-new-cluster" "$rto_file" "COMPLETED")
    log_info "详细报告已保存到: $report_dir"
}

# 执行主函数
main
