#!/bin/bash
# utils.sh - 工具函数库
# 提供通用的辅助函数供其他脚本使用

set -euo pipefail

# 颜色输出
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# 日志函数
log_info() {
    echo -e "${BLUE}[INFO]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

log_success() {
    echo -e "${GREEN}[SUCCESS]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

log_warning() {
    echo -e "${YELLOW}[WARNING]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $(date '+%Y-%m-%d %H:%M:%S') - $1" >&2
}

# 检查必需的命令是否存在
check_prerequisites() {
    local required_commands=("aws" "kubectl" "jq")

    for cmd in "${required_commands[@]}"; do
        if ! command -v "$cmd" &> /dev/null; then
            log_error "必需命令 '$cmd' 未安装"
            exit 1
        fi
    done

    log_success "前置条件检查通过"
}

# 检查 AWS 凭证
check_aws_credentials() {
    if ! aws sts get-caller-identity &> /dev/null; then
        log_error "AWS 凭证无效或未配置"
        exit 1
    fi

    local account_id=$(aws sts get-caller-identity --query Account --output text)
    local user_arn=$(aws sts get-caller-identity --query Arn --output text)
    log_info "AWS 账户: $account_id"
    log_info "IAM 身份: $user_arn"
}

# 等待 EKS 集群就绪
wait_for_cluster_active() {
    local cluster_name=$1
    local max_wait=${2:-600}  # 默认最长等待 10 分钟
    local elapsed=0

    log_info "等待集群 $cluster_name 变为 ACTIVE 状态..."

    while [ $elapsed -lt $max_wait ]; do
        local status=$(aws eks describe-cluster --name "$cluster_name" \
            --query 'cluster.status' --output text 2>/dev/null || echo "NOT_FOUND")

        if [ "$status" = "ACTIVE" ]; then
            log_success "集群 $cluster_name 已就绪"
            return 0
        fi

        log_info "当前状态: $status (已等待 ${elapsed}s/${max_wait}s)"
        sleep 10
        elapsed=$((elapsed + 10))
    done

    log_error "集群 $cluster_name 在 ${max_wait}s 内未变为 ACTIVE 状态"
    return 1
}

# 等待备份作业完成
wait_for_backup_job() {
    local backup_job_id=$1
    local max_wait=${2:-3600}  # 默认最长等待 1 小时
    local elapsed=0

    log_info "等待备份作业 $backup_job_id 完成..."

    while [ $elapsed -lt $max_wait ]; do
        local status=$(aws backup describe-backup-job --backup-job-id "$backup_job_id" \
            --query 'State' --output text 2>/dev/null || echo "NOT_FOUND")

        case "$status" in
            "COMPLETED")
                log_success "备份作业完成"
                return 0
                ;;
            "FAILED"|"ABORTED")
                log_error "备份作业失败,状态: $status"
                aws backup describe-backup-job --backup-job-id "$backup_job_id"
                return 1
                ;;
            "RUNNING"|"CREATED")
                log_info "备份进行中... (已等待 ${elapsed}s/${max_wait}s)"
                ;;
        esac

        sleep 30
        elapsed=$((elapsed + 30))
    done

    log_error "备份作业在 ${max_wait}s 内未完成"
    return 1
}

# 等待恢复作业完成
wait_for_restore_job() {
    local restore_job_id=$1
    local max_wait=${2:-3600}  # 默认最长等待 1 小时
    local elapsed=0

    log_info "等待恢复作业 $restore_job_id 完成..."

    while [ $elapsed -lt $max_wait ]; do
        local status=$(aws backup describe-restore-job --restore-job-id "$restore_job_id" \
            --query 'Status' --output text 2>/dev/null || echo "NOT_FOUND")

        case "$status" in
            "COMPLETED")
                log_success "恢复作业完成"
                return 0
                ;;
            "FAILED"|"ABORTED")
                log_error "恢复作业失败,状态: $status"
                aws backup describe-restore-job --restore-job-id "$restore_job_id"
                return 1
                ;;
            "RUNNING"|"PENDING"|"CREATED")
                log_info "恢复进行中... (已等待 ${elapsed}s/${max_wait}s)"
                ;;
        esac

        sleep 30
        elapsed=$((elapsed + 30))
    done

    log_error "恢复作业在 ${max_wait}s 内未完成"
    return 1
}

# 等待托管 Add-on 就绪
wait_for_addon_active() {
    local cluster_name=$1
    local addon_name=$2
    local max_wait=${3:-600}  # 默认最长等待 10 分钟
    local elapsed=0

    log_info "等待 Add-on $addon_name 变为 ACTIVE 状态..."

    while [ $elapsed -lt $max_wait ]; do
        local status=$(aws eks describe-addon \
            --cluster-name "$cluster_name" \
            --addon-name "$addon_name" \
            --query 'addon.status' --output text 2>/dev/null || echo "NOT_FOUND")

        case "$status" in
            "ACTIVE")
                log_success "Add-on $addon_name 已就绪"
                return 0
                ;;
            "CREATE_FAILED"|"DEGRADED")
                log_error "Add-on $addon_name 状态异常: $status"
                return 1
                ;;
            *)
                log_info "Add-on 状态: $status (已等待 ${elapsed}s/${max_wait}s)"
                ;;
        esac

        sleep 10
        elapsed=$((elapsed + 10))
    done

    log_error "Add-on $addon_name 在 ${max_wait}s 内未变为 ACTIVE 状态"
    return 1
}

# 配置 kubectl 上下文
configure_kubectl() {
    local cluster_name=$1
    local region=${2:-us-west-2}

    log_info "配置 kubectl 上下文: $cluster_name (区域: $region)"

    if ! aws eks update-kubeconfig \
        --name "$cluster_name" \
        --region "$region" \
        --alias "$cluster_name"; then
        log_error "配置 kubectl 失败"
        return 1
    fi

    if ! kubectl cluster-info &> /dev/null; then
        log_error "无法连接到集群"
        return 1
    fi

    log_success "kubectl 配置成功"
}

# 验证集群版本
verify_cluster_version() {
    local cluster_name=$1
    local expected_version=$2

    local actual_version=$(aws eks describe-cluster --name "$cluster_name" \
        --query 'cluster.version' --output text)

    if [ "$actual_version" = "$expected_version" ]; then
        log_success "集群版本验证通过: $actual_version"
        return 0
    else
        log_error "集群版本不匹配: 期望 $expected_version, 实际 $actual_version"
        return 1
    fi
}

# 获取恢复点 ARN
get_latest_recovery_point() {
    local resource_arn=$1
    local backup_vault=${2:-}

    # If vault not provided, try to get from Terraform output
    if [ -z "$backup_vault" ]; then
        backup_vault=$(cd "$(dirname "${BASH_SOURCE[0]}")/../terraform" && terraform output -raw backup_vault_name 2>/dev/null || echo "Default")
    fi

    local recovery_point=$(aws backup list-recovery-points-by-resource \
        --resource-arn "$resource_arn" \
        --query 'RecoveryPoints | sort_by(@, &CreationDate) | [-1].RecoveryPointArn' \
        --output text)

    if [ -z "$recovery_point" ] || [ "$recovery_point" = "None" ]; then
        log_error "未找到恢复点"
        return 1
    fi

    echo "$recovery_point"
}

# 记录时间戳
timestamp() {
    date '+%Y-%m-%d %H:%M:%S'
}

# 记录时间戳到文件（用于 RTO 测量）
record_timestamp() {
    local label=$1
    local output_file=$2

    echo "$(timestamp),$label" >> "$output_file"
    log_info "$label: $(timestamp)"
}

# 验证 PVC 状态
verify_pvc_status() {
    local namespace=$1
    local timeout=${2:-300}
    local elapsed=0

    log_info "验证命名空间 $namespace 中的 PVC 状态..."

    while [ $elapsed -lt $timeout ]; do
        local pending_count=$(kubectl get pvc -n "$namespace" \
            -o json 2>/dev/null | jq -r '.items[] | select(.status.phase != "Bound") | .metadata.name' | wc -l)

        if [ "$pending_count" -eq 0 ]; then
            log_success "所有 PVC 已绑定"
            kubectl get pvc -n "$namespace"
            return 0
        fi

        log_info "等待 PVC 绑定... ($pending_count 个 PVC 仍在等待,已等待 ${elapsed}s)"
        sleep 10
        elapsed=$((elapsed + 10))
    done

    log_error "PVC 在 ${timeout}s 内未全部绑定"
    kubectl get pvc -n "$namespace"
    return 1
}

# 验证 Pod 状态
verify_pod_status() {
    local namespace=$1
    local timeout=${2:-300}
    local elapsed=0

    log_info "验证命名空间 $namespace 中的 Pod 状态..."

    while [ $elapsed -lt $timeout ]; do
        local not_running=$(kubectl get pods -n "$namespace" \
            -o json 2>/dev/null | jq -r '.items[] | select(.status.phase != "Running" and .status.phase != "Succeeded") | .metadata.name' | wc -l)

        if [ "$not_running" -eq 0 ]; then
            log_success "所有 Pod 运行正常"
            kubectl get pods -n "$namespace"
            return 0
        fi

        log_info "等待 Pod 就绪... ($not_running 个 Pod 未就绪,已等待 ${elapsed}s)"
        sleep 10
        elapsed=$((elapsed + 10))
    done

    log_error "Pod 在 ${timeout}s 内未全部就绪"
    kubectl get pods -n "$namespace"
    return 1
}

# 生成测试报告
generate_test_report() {
    local test_name=$1
    local result_file=$2
    local status=$3  # PASS 或 FAIL

    local report_dir="/home/ubuntu/aws-backup-test/results/test-run-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$report_dir"

    cat > "$report_dir/${test_name}-report.md" <<EOF
# 测试报告: $test_name

**测试时间**: $(timestamp)
**测试状态**: $status
**执行者**: $(whoami)
**AWS 账户**: $(aws sts get-caller-identity --query Account --output text)

## 测试结果

EOF

    if [ -f "$result_file" ]; then
        cat "$result_file" >> "$report_dir/${test_name}-report.md"
    fi

    log_info "测试报告已生成: $report_dir/${test_name}-report.md"
    echo "$report_dir"
}

# 清理资源（带确认）
cleanup_resources() {
    local cluster_name=$1
    local force=${2:-false}

    if [ "$force" != "true" ]; then
        read -p "确认要删除集群 $cluster_name 吗? (yes/no): " confirm
        if [ "$confirm" != "yes" ]; then
            log_info "取消删除操作"
            return 0
        fi
    fi

    log_warning "开始删除集群 $cluster_name..."

    # 删除集群
    if aws eks describe-cluster --name "$cluster_name" &> /dev/null; then
        aws eks delete-cluster --name "$cluster_name"
        log_info "集群删除已启动"
    else
        log_info "集群不存在,跳过"
    fi
}

# 导出函数供其他脚本使用
export -f log_info log_success log_warning log_error
export -f check_prerequisites check_aws_credentials
export -f wait_for_cluster_active wait_for_backup_job wait_for_restore_job wait_for_addon_active
export -f configure_kubectl verify_cluster_version get_latest_recovery_point
export -f timestamp record_timestamp
export -f verify_pvc_status verify_pod_status
export -f generate_test_report cleanup_resources
