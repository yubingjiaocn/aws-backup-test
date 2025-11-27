#!/bin/bash
# 00-setup-environment.sh - 环境准备脚本
# 创建测试用的 EKS 集群和测试工作负载

set -euo pipefail

# 加载工具函数
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
source "$SCRIPT_DIR/utils.sh"

# 默认配置
CLUSTER_NAME="${CLUSTER_NAME:-eks-backup-test-source}"
REGION="${REGION:-us-west-2}"
K8S_VERSION="${K8S_VERSION:-1.32}"
NODE_TYPE="${NODE_TYPE:-t3.medium}"
NODE_COUNT="${NODE_COUNT:-2}"

# 使用说明
usage() {
    cat <<EOF
使用方法: $0 [选项]

选项:
  -n, --cluster-name NAME    集群名称 (默认: eks-backup-test-source)
  -r, --region REGION        AWS 区域 (默认: us-west-2)
  -v, --version VERSION      Kubernetes 版本 (默认: 1.32)
  -t, --node-type TYPE       节点实例类型 (默认: m7i-flex.xlarge)
  -c, --node-count COUNT     节点数量 (默认: 2)
  -h, --help                 显示帮助信息

示例:
  $0 --cluster-name my-cluster --region us-east-1 --version 1.33
EOF
    exit 1
}

# 解析命令行参数
while [[ $# -gt 0 ]]; do
    case $1 in
        -n|--cluster-name)
            CLUSTER_NAME="$2"
            shift 2
            ;;
        -r|--region)
            REGION="$2"
            shift 2
            ;;
        -v|--version)
            K8S_VERSION="$2"
            shift 2
            ;;
        -t|--node-type)
            NODE_TYPE="$2"
            shift 2
            ;;
        -c|--node-count)
            NODE_COUNT="$2"
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
    log_info "AWS Backup EKS 测试环境准备"
    log_info "=========================================="

    # 检查前置条件
    check_prerequisites
    check_aws_credentials

    log_info "配置信息:"
    log_info "  集群名称: $CLUSTER_NAME"
    log_info "  区域: $REGION"
    log_info "  Kubernetes 版本: $K8S_VERSION"
    log_info "  节点类型: $NODE_TYPE"
    log_info "  节点数量: $NODE_COUNT"

    log_info "步骤 1/7: 创建基础设施 (Terraform)..."
    create_terraform_infrastructure

    # 检查集群是否已存在
    if aws eks describe-cluster --name "$CLUSTER_NAME" --region "$REGION" &> /dev/null; then
        log_warning "集群 $CLUSTER_NAME 已存在"
        read -p "是否使用现有集群并跳过创建? (yes/no): " use_existing
        if [ "$use_existing" = "yes" ]; then
            log_info "使用现有集群"
        else
            log_error "请更改集群名称或删除现有集群"
            exit 1
        fi
    else
        log_info "步骤 2/7: 创建 EKS 集群 (eksctl)..."
        create_eks_cluster
    fi

    log_info "步骤 3/7: 配置 kubectl..."
    configure_kubectl "$CLUSTER_NAME" "$REGION"

    log_info "步骤 4/7: 验证 CSI Driver 状态..."
    verify_csi_drivers

    log_info "步骤 5/7: 部署测试工作负载..."
    deploy_test_workloads

    log_info "步骤 6/7: 写入测试数据..."
    write_test_data

    log_info "步骤 7/7: 验证环境..."
    verify_environment

    log_success "=========================================="
    log_success "环境准备完成!"
    log_success "=========================================="
    log_info "集群名称: $CLUSTER_NAME"
    log_info "区域: $REGION"
    log_info "Kubernetes 版本: $K8S_VERSION"
    log_info ""
    log_info "下一步: 运行备份脚本"
    log_info "  ./scripts/01-create-backup.sh $CLUSTER_NAME"
}

create_terraform_infrastructure() {
    log_info "使用 Terraform 创建基础设施..."

    # 检查 Terraform 是否安装
    if ! command -v terraform &> /dev/null; then
        log_error "Terraform 未安装,请安装后重试"
        log_info "安装方法: https://developer.hashicorp.com/terraform/downloads"
        exit 1
    fi

    # 进入 Terraform 目录
    local terraform_dir="$SCRIPT_DIR/../terraform"
    cd "$terraform_dir" || {
        log_error "无法进入 Terraform 目录: $terraform_dir"
        exit 1
    }

    # 初始化 Terraform
    log_info "初始化 Terraform..."
    terraform init

    # 查看将要创建的资源
    log_info "查看 Terraform 计划..."
    terraform plan

    # 创建基础设施
    log_info "创建基础设施 (约 5-7 分钟)..."
    terraform apply -auto-approve

    # 获取 Terraform 输出的集群名称
    CLUSTER_NAME=$(terraform output -raw cluster_name)
    export CLUSTER_NAME

    # 返回原目录
    cd - > /dev/null

    log_success "基础设施创建完成"
    log_info "创建的资源:"
    log_info "  ✅ VPC (包含公有和私有子网)"
    log_info "  ✅ NAT 网关 (单个,成本优化)"
    log_info "  ✅ IAM 角色（用于 EKS 控制平面和节点）"
    log_info "  ✅ IAM 角色（用于 AWS Backup 服务）"
    log_info "  ✅ AWS Backup 保管库"
    log_info "  ✅ EFS 文件系统"
    log_info "  ✅ 安全组"
    log_info ""
    log_info "集群名称 (从 Terraform 获取): $CLUSTER_NAME"
}

create_eks_cluster() {
    log_info "使用 eksctl 创建集群..."

    # 检查 eksctl 是否安装
    if ! command -v eksctl &> /dev/null; then
        log_error "eksctl 未安装,请安装后重试"
        log_info "安装方法: https://eksctl.io/introduction/#installation"
        exit 1
    fi

    # 生成 eksctl 配置
    log_info "生成 eksctl 配置文件..."
    "$SCRIPT_DIR/../eksctl-config/export-tf-outputs.sh" "$K8S_VERSION"

    # 检查生成的配置文件是否存在
    local config_file="$SCRIPT_DIR/../eksctl-config/cluster-generated.yaml"
    if [ ! -f "$config_file" ]; then
        log_error "eksctl 配置文件生成失败: $config_file"
        exit 1
    fi

    # 创建 EKS 集群 (约 15-20 分钟)
    log_info "创建 EKS 集群 (约 15-20 分钟)..."
    log_info "此步骤会自动安装以下 add-ons:"
    log_info "  - eks-pod-identity-agent"
    log_info "  - aws-ebs-csi-driver (最新版本)"
    log_info "  - aws-efs-csi-driver (最新版本)"
    log_info "所有 addons 的 IAM 权限通过 autoApplyPodIdentityAssociations 自动配置"

    eksctl create cluster -f "$config_file"

    log_success "集群创建完成"

    # 等待集群就绪
    wait_for_cluster_active "$CLUSTER_NAME" 600
}

verify_csi_drivers() {
    log_info "验证 CSI driver pods 是否运行..."

    # 等待 CSI driver pods 就绪
    local max_wait=300
    local elapsed=0
    local interval=10

    while [ $elapsed -lt $max_wait ]; do
        local ebs_ready=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-ebs-csi-driver --no-headers 2>/dev/null | grep -c Running || echo "0")
        local efs_ready=$(kubectl get pods -n kube-system -l app.kubernetes.io/name=aws-efs-csi-driver --no-headers 2>/dev/null | grep -c Running || echo "0")

        if [ "$ebs_ready" -gt 0 ] && [ "$efs_ready" -gt 0 ]; then
            log_success "CSI drivers 已就绪"
            log_info "  EBS CSI Driver pods: $ebs_ready"
            log_info "  EFS CSI Driver pods: $efs_ready"
            return 0
        fi

        log_info "等待 CSI driver pods 就绪... ($elapsed/$max_wait 秒)"
        sleep $interval
        elapsed=$((elapsed + interval))
    done

    log_warning "CSI drivers 未完全就绪,但继续执行"
    kubectl get pods -n kube-system | grep -E "ebs-csi|efs-csi" || true
}

deploy_test_workloads() {
    log_info "部署测试工作负载..."

    # 应用测试命名空间
    kubectl apply -f "$SCRIPT_DIR/../test-workloads/namespace.yaml" || true

    # 部署 EBS 工作负载 (StatefulSet)
    log_info "部署 EBS 工作负载..."
    kubectl apply -f "$SCRIPT_DIR/../test-workloads/statefulset-ebs.yaml"

    # 获取 EFS 文件系统 ID 并更新 deployment-efs.yaml
    log_info "获取 EFS 文件系统 ID..."
    local terraform_dir="$SCRIPT_DIR/../terraform"
    cd "$terraform_dir" || {
        log_error "无法进入 Terraform 目录: $terraform_dir"
        exit 1
    }
    local EFS_ID=$(terraform output -raw efs_filesystem_id)
    cd - > /dev/null

    if [ -z "$EFS_ID" ]; then
        log_error "无法获取 EFS 文件系统 ID"
        exit 1
    fi

    log_info "EFS 文件系统 ID: $EFS_ID"

    # 更新 EFS deployment 配置
    log_info "更新 EFS deployment 配置..."
    local efs_deployment="$SCRIPT_DIR/../test-workloads/deployment-efs.yaml"
    sed -i "s/fs-XXXXXXXXX/$EFS_ID/" "$efs_deployment"

    # 部署 EFS 工作负载
    log_info "部署 EFS 工作负载..."
    kubectl apply -f "$efs_deployment"

    # 安装 Karpenter
    log_info "安装 Karpenter (约 2-3 分钟)..."
    "$SCRIPT_DIR/04-install-karpenter.sh" "$CLUSTER_NAME"

    # 部署 Karpenter NodePool
    log_info "部署 Karpenter NodePool..."
    kubectl apply -f "$SCRIPT_DIR/../test-workloads/karpenter-nodepool.yaml"

    log_info "等待 Pod 就绪..."
    sleep 30

    # 验证 Pod 状态
    verify_pod_status "test" 300

    log_success "测试工作负载部署完成"
}

write_test_data() {
    log_info "写入测试数据..."

    # 等待 StatefulSet Pod 就绪
    kubectl wait --for=condition=ready pod/mysql-statefulset-0 -n test --timeout=300s || true

    # 写入测试数据到 EBS 卷
    kubectl exec -n test mysql-statefulset-0 -- bash -c "
        echo 'Test data for AWS Backup EKS - $(date)' > /data/test_file.txt
        echo 'Backup timestamp: $(date +%s)' > /data/timestamp.txt
    "

    log_success "测试数据写入完成"
}

verify_environment() {
    log_info "验证环境配置..."

    # 验证集群版本
    verify_cluster_version "$CLUSTER_NAME" "$K8S_VERSION"

    # 验证节点
    local node_count=$(kubectl get nodes --no-headers | wc -l)
    log_info "节点数量: $node_count"

    # 验证托管 Add-on
    log_info "验证托管 Add-on..."
    aws eks describe-addon --cluster-name "$CLUSTER_NAME" --addon-name aws-ebs-csi-driver --region "$REGION" --query 'addon.status' --output text
    aws eks describe-addon --cluster-name "$CLUSTER_NAME" --addon-name aws-efs-csi-driver --region "$REGION" --query 'addon.status' --output text

    # 验证 PVC
    log_info "验证 PVC 状态..."
    kubectl get pvc -n test

    # 验证 CRD
    log_info "验证 Karpenter CRD..."
    kubectl get crd | grep karpenter || log_warning "Karpenter CRD 未找到"

    log_success "环境验证完成"
}

# 执行主函数
main
