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
# Try to get backup vault from Terraform output, fallback to "Default"
if [ -z "${BACKUP_VAULT:-}" ]; then
    BACKUP_VAULT=$(cd "$(dirname "$0")/../terraform" && terraform output -raw backup_vault_name 2>/dev/null || echo "Default")
fi

# 使用说明
usage() {
    cat <<EOF
使用方法: $0 [选项]

选项:
  --recovery-point-arn ARN  恢复点 ARN (必需)
  --cluster-name NAME       新集群名称 (必需)
  --eks-version VERSION     EKS 版本 (必需,例如: 1.32)
  -r, --region REGION       AWS 区域 (默认: us-west-2)
  -v, --vault VAULT         备份保管库名称 (默认: 从 Terraform 获取或 Default)
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
        -v|--vault)
            BACKUP_VAULT="$2"
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
    log_info "  备份保管库: $BACKUP_VAULT"

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
    log_info "  验证恢复: ./scripts/05-verify-restore.sh $NEW_CLUSTER_NAME"
}

get_backup_vault_from_recovery_point() {
    log_info "检测恢复点所在的备份保管库..."

    # Try to get vault name from recovery point metadata
    local vault_from_rp=$(aws backup describe-recovery-point \
        --recovery-point-arn "$RECOVERY_POINT_ARN" \
        --region "$REGION" \
        --query 'BackupVaultName' \
        --output text 2>/dev/null)

    if [ -n "$vault_from_rp" ] && [ "$vault_from_rp" != "None" ]; then
        log_info "从恢复点检测到备份保管库: $vault_from_rp"
        echo "$vault_from_rp"
        return 0
    fi

    # Fallback to the BACKUP_VAULT variable
    log_info "使用配置的备份保管库: $BACKUP_VAULT"
    echo "$BACKUP_VAULT"
}

get_source_cluster_config() {
    log_info "从恢复点获取源集群配置..."

    # Ensure we have the correct backup vault
    local detected_vault=$(get_backup_vault_from_recovery_point)
    if [ "$detected_vault" != "$BACKUP_VAULT" ]; then
        log_warning "检测到的保管库 ($detected_vault) 与配置的保管库 ($BACKUP_VAULT) 不同"
        log_info "使用检测到的保管库: $detected_vault"
        BACKUP_VAULT="$detected_vault"
    fi

    # 从恢复点 ARN 提取信息
    # 格式: arn:aws:backup:region:account:recovery-point:resource-id
    local resource_id=$(echo "$RECOVERY_POINT_ARN" | awk -F':' '{print $NF}')

    # 获取恢复点详情
    local recovery_point=$(aws backup describe-recovery-point \
        --recovery-point-arn "$RECOVERY_POINT_ARN" \
        --backup-vault-name "$BACKUP_VAULT" \
        --region "$REGION" \
        --output json)

    # Extract source cluster name from ResourceArn
    local source_cluster_arn=$(echo "$recovery_point" | jq -r '.ResourceArn')
    local source_cluster_name=$(echo "$source_cluster_arn" | awk -F'/' '{print $NF}')

    log_info "源集群名称: $source_cluster_name"

    # Get the source cluster's node groups information
    log_info "获取源集群的节点组配置..."
    local node_groups_info=$(aws eks list-nodegroups \
        --cluster-name "$source_cluster_name" \
        --region "$REGION" \
        --output json 2>/dev/null || echo '{"nodegroups":[]}')

    # Get child recovery points for nested restores
    log_info "获取子恢复点信息..."
    local child_recovery_points=$(aws backup list-recovery-points-by-backup-vault \
        --backup-vault-name "$BACKUP_VAULT" \
        --region "$REGION" \
        --by-parent-recovery-point-arn "$RECOVERY_POINT_ARN" \
        --output json)

    local child_count=$(echo "$child_recovery_points" | jq '.RecoveryPoints | length')
    log_info "找到 $child_count 个子恢复点"

    # Store node group info and child recovery points for later use
    echo "$recovery_point" | jq --argjson nodegroups "$node_groups_info" \
        --argjson childPoints "$child_recovery_points" \
        '. + {sourceNodeGroups: $nodegroups, childRecoveryPoints: $childPoints}'
}

prepare_restore_metadata() {
    local source_config=$1

    log_info "准备恢复元数据..."

    # 获取当前账户信息
    local account_id=$(aws sts get-caller-identity --query Account --output text)

    # Extract source cluster name and node groups
    local source_cluster_arn=$(echo "$source_config" | jq -r '.ResourceArn')
    local source_cluster_name=$(echo "$source_cluster_arn" | awk -F'/' '{print $NF}')
    local source_node_group_names=$(echo "$source_config" | jq -r '.sourceNodeGroups.nodegroups[]' 2>/dev/null || echo "")

    # Try to get IAM role ARNs from Terraform outputs first
    local cluster_role_arn=""
    local node_role_arn=""

    if [ -d "$SCRIPT_DIR/../terraform" ]; then
        local terraform_dir="$SCRIPT_DIR/../terraform"

        cluster_role_arn=$(cd "$terraform_dir" && terraform output -raw cluster_role_arn 2>/dev/null || echo "")
        node_role_arn=$(cd "$terraform_dir" && terraform output -raw node_role_arn 2>/dev/null || echo "")

        if [ -n "$cluster_role_arn" ] && [ "$cluster_role_arn" != "null" ]; then
            log_success "从 Terraform 获取 IAM 角色配置"
            log_info "  Cluster Role: $cluster_role_arn"
            log_info "  Node Role: $node_role_arn"
        else
            log_warning "Terraform 未配置 IAM 角色,使用默认命名..."
            cluster_role_arn="arn:aws:iam::${account_id}:role/eksClusterRole"
            node_role_arn="arn:aws:iam::${account_id}:role/eksNodeRole"
        fi
    else
        log_warning "Terraform 目录不存在,使用默认 IAM 角色命名..."
        cluster_role_arn="arn:aws:iam::${account_id}:role/eksClusterRole"
        node_role_arn="arn:aws:iam::${account_id}:role/eksNodeRole"
    fi

    # 获取 VPC 和子网配置
    local vpc_config=$(get_vpc_config)
    local vpc_id=$(echo "$vpc_config" | jq -r '.vpcId')
    local all_subnet_ids=$(echo "$vpc_config" | jq -r '.subnetIds')

    # Build clusterVpcConfig as a proper JSON string
    local cluster_vpc_config=$(echo "$vpc_config" | jq -c '.')

    # Build node groups configuration
    local node_groups_json="[]"
    if [ -n "$source_node_group_names" ]; then
        log_info "构建节点组配置..."
        local node_groups_array="[]"

        for ng_name in $source_node_group_names; do
            log_info "  处理节点组: $ng_name"

            # Get node group details from source cluster
            local ng_info=$(aws eks describe-nodegroup \
                --cluster-name "$source_cluster_name" \
                --nodegroup-name "$ng_name" \
                --region "$REGION" \
                --output json 2>/dev/null)

            if [ -n "$ng_info" ]; then
                # Extract required fields
                local ng_subnets=$(echo "$ng_info" | jq -c '.nodegroup.subnets')
                local ng_instance_types=$(echo "$ng_info" | jq -c '.nodegroup.instanceTypes')
                local ng_node_role=$(echo "$ng_info" | jq -r '.nodegroup.nodeRole')

                # Build node group config
                local ng_config=$(jq -n \
                    --arg nodeGroupId "$ng_name" \
                    --argjson subnetIds "$ng_subnets" \
                    --argjson instanceTypes "$ng_instance_types" \
                    --arg nodeRole "$node_role_arn" \
                    '{
                        nodeGroupId: $nodeGroupId,
                        subnetIds: $subnetIds,
                        instanceTypes: $instanceTypes,
                        nodeRole: $nodeRole
                    }')

                node_groups_array=$(echo "$node_groups_array" | jq --argjson ng "$ng_config" '. + [$ng]')
                log_success "  ✓ 节点组 $ng_name 配置完成"
            else
                log_warning "  ⚠ 无法获取节点组 $ng_name 的详细信息"
            fi
        done

        # Convert to JSON string for metadata
        node_groups_json=$(echo "$node_groups_array" | jq -c '.')
    fi

    # Build nested restore jobs metadata for child recovery points
    log_info "构建子恢复点元数据..."
    local child_recovery_points=$(echo "$source_config" | jq -c '.childRecoveryPoints.RecoveryPoints')
    local nested_restore_metadata="{}"

    if [ "$child_recovery_points" != "null" ] && [ "$child_recovery_points" != "[]" ]; then
        # Get available AZs for the region
        local available_azs=$(aws ec2 describe-availability-zones \
            --region "$REGION" \
            --filters "Name=state,Values=available" \
            --query 'AvailabilityZones[0].ZoneName' \
            --output text)

        local az_to_use="${available_azs}"

        log_info "  可用区: $az_to_use"

        # Process each child recovery point
        for rp_arn in $(echo "$child_recovery_points" | jq -r '.[].RecoveryPointArn'); do
            local rp_type=$(echo "$child_recovery_points" | jq -r --arg arn "$rp_arn" '.[] | select(.RecoveryPointArn == $arn) | .ResourceType')

            log_info "  处理子恢复点: $rp_type"

            case "$rp_type" in
                "EBS")
                    # EBS volumes need availability zone
                    # Note: The value must be a JSON string, not an object
                    local ebs_metadata=$(jq -n --arg az "$az_to_use" '{"availabilityZone": $az}' | jq -c '.')
                    nested_restore_metadata=$(echo "$nested_restore_metadata" | jq \
                        --arg rpArn "$rp_arn" \
                        --arg metadata "$ebs_metadata" \
                        '. + {($rpArn): $metadata}')
                    log_success "    ✓ EBS 恢复点配置完成 (AZ: $az_to_use)"
                    ;;
                "EFS")
                    # EFS needs newFileSystem parameter
                    # Set to "true" to create a new file system
                    local efs_metadata=$(jq -n '{"newFileSystem": "true", "PerformanceMode": "generalPurpose"}' | jq -c '.')
                    nested_restore_metadata=$(echo "$nested_restore_metadata" | jq \
                        --arg rpArn "$rp_arn" \
                        --arg metadata "$efs_metadata" \
                        '. + {($rpArn): $metadata}')
                    log_success "    ✓ EFS 恢复点配置完成 (新文件系统)"
                    ;;
                *)
                    # Other types use empty metadata
                    nested_restore_metadata=$(echo "$nested_restore_metadata" | jq \
                        --arg rpArn "$rp_arn" \
                        --arg metadata "{}" \
                        '. + {($rpArn): $metadata}')
                    log_success "    ✓ $rp_type 恢复点配置完成"
                    ;;
            esac
        done
    fi

    # Convert nested metadata to JSON string
    local nested_restore_json=$(echo "$nested_restore_metadata" | jq -c '.')

    log_info "恢复元数据准备完成:"
    log_info "  集群名称: $NEW_CLUSTER_NAME"
    log_info "  EKS 版本: $EKS_VERSION"
    log_info "  VPC ID: $vpc_id"
    log_info "  子网数量: $(echo "$vpc_config" | jq -r '.subnetIds | length')"
    log_info "  节点组数量: $(echo "$node_groups_json" | jq '. | length')"
    log_info "  子恢复点数量: $(echo "$child_recovery_points" | jq '. | length')"

    # 构建恢复元数据
    jq -n \
        --arg clusterName "$NEW_CLUSTER_NAME" \
        --arg eksClusterVersion "$EKS_VERSION" \
        --arg clusterRole "$cluster_role_arn" \
        --arg clusterVpcConfig "$cluster_vpc_config" \
        --arg nodeGroups "$node_groups_json" \
        --arg nestedRestoreJobs "$nested_restore_json" \
        '{
            clusterName: $clusterName,
            newCluster: "true",
            eksClusterVersion: $eksClusterVersion,
            clusterRole: $clusterRole,
            clusterVpcConfig: $clusterVpcConfig,
            nodeGroups: $nodeGroups,
            nestedRestoreJobs: $nestedRestoreJobs
        }'
}

get_vpc_config() {
    log_info "获取 VPC 和子网配置..."

    # Try to get VPC and subnets from Terraform outputs first
    if [ -d "$SCRIPT_DIR/../terraform" ]; then
        local terraform_dir="$SCRIPT_DIR/../terraform"

        local vpc_id=$(cd "$terraform_dir" && terraform output -raw vpc_id 2>/dev/null || echo "")
        local private_subnets=$(cd "$terraform_dir" && terraform output -json private_subnet_ids 2>/dev/null || echo "[]")
        local public_subnets=$(cd "$terraform_dir" && terraform output -json public_subnet_ids 2>/dev/null || echo "[]")

        if [ -n "$vpc_id" ] && [ "$vpc_id" != "null" ]; then
            log_success "从 Terraform 获取 VPC 配置"
            log_info "  VPC ID: $vpc_id"

            # Combine private and public subnets
            local all_subnets=$(echo "$private_subnets $public_subnets" | jq -s 'add | unique')
            local subnet_count=$(echo "$all_subnets" | jq '. | length')

            if [ "$subnet_count" -ge 2 ]; then
                log_info "  子网数量: $subnet_count"
                local subnet_ids=$(echo "$all_subnets" | jq -r 'map("\"" + . + "\"") | join(",")')

                cat <<EOF
{
  "vpcId": "$vpc_id",
  "subnetIds": [$subnet_ids]
}
EOF
                return 0
            else
                log_warning "Terraform 输出的子网数量不足,尝试使用默认 VPC..."
            fi
        else
            log_warning "Terraform 未配置 VPC,尝试使用默认 VPC..."
        fi
    fi

    # Fallback: 获取默认 VPC
    log_info "使用默认 VPC 配置..."
    local vpc_id=$(aws ec2 describe-vpcs \
        --filters "Name=is-default,Values=true" \
        --region "$REGION" \
        --query 'Vpcs[0].VpcId' \
        --output text)

    if [ -z "$vpc_id" ] || [ "$vpc_id" = "None" ]; then
        log_error "未找到默认 VPC"
        log_error "请确保:"
        log_error "  1. 已运行 'terraform apply' 创建 VPC"
        log_error "  2. 或者 AWS 账户有默认 VPC"
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

    log_info "  VPC ID: $vpc_id"
    log_info "  子网数量: $subnet_count"

    # 取所有子网
    local subnet_ids=$(echo "$subnets" | jq -r 'map("\"" + . + "\"") | join(",")')

    cat <<EOF
{
  "vpcId": "$vpc_id",
  "subnetIds": [$subnet_ids]
}
EOF
}

ensure_restore_role() {
    # Try to get role ARN from Terraform output first
    local role_arn=""
    local role_name=""

    # Check if terraform directory exists and has outputs
    if [ -d "$SCRIPT_DIR/../terraform" ]; then
        role_arn=$(cd "$SCRIPT_DIR/../terraform" && terraform output -raw aws_backup_role_arn 2>/dev/null || echo "")
    fi

    if [ -n "$role_arn" ] && [ "$role_arn" != "null" ]; then
        role_name=$(echo "$role_arn" | awk -F'/' '{print $NF}')
        log_info "使用 Terraform 创建的 IAM 角色: $role_name"

        # Verify the role exists
        if aws iam get-role --role-name "$role_name" &> /dev/null; then
            log_success "IAM 角色验证成功"
            echo "$role_arn"
            return 0
        else
            log_warning "Terraform 输出的角色不存在，尝试查找其他角色..."
        fi
    fi

    # Fallback: try cluster-specific role name pattern
    local cluster_role_pattern="AWSBackupServiceRole-*"
    local found_role=$(aws iam list-roles --query "Roles[?starts_with(RoleName, 'AWSBackupServiceRole-')].RoleName" --output text | head -n1)

    if [ -n "$found_role" ]; then
        local found_role_arn="arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/$found_role"
        log_info "找到 IAM 角色: $found_role"
        echo "$found_role_arn"
        return 0
    fi

    # Fallback: try default role name
    local default_role_name="AWSBackupDefaultServiceRole"
    local default_role_arn="arn:aws:iam::$(aws sts get-caller-identity --query Account --output text):role/$default_role_name"

    if aws iam get-role --role-name "$default_role_name" &> /dev/null; then
        log_info "找到默认 IAM 角色: $default_role_name"
        echo "$default_role_arn"
        return 0
    fi

    # No role found
    log_error "未找到 AWS Backup IAM 角色"
    log_error "请确保已运行 'terraform apply' 创建基础设施"
    log_error "角色应该在 terraform apply 时自动创建"
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
