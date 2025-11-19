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
  -t, --node-type TYPE       节点实例类型 (默认: t3.medium)
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
        log_info "步骤 1/7: 创建 EKS 集群..."
        create_eks_cluster
    fi

    log_info "步骤 2/7: 配置 kubectl..."
    configure_kubectl "$CLUSTER_NAME" "$REGION"

    log_info "步骤 3/7: 启用托管 Add-on (EBS/EFS CSI Drivers)..."
    enable_managed_addons

    log_info "步骤 4/7: 部署测试工作负载..."
    deploy_test_workloads

    log_info "步骤 5/7: 部署 Karpenter..."
    deploy_karpenter

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

create_eks_cluster() {
    log_info "使用 eksctl 创建集群..."

    # 检查 eksctl 是否安装
    if ! command -v eksctl &> /dev/null; then
        log_error "eksctl 未安装,请安装后重试"
        log_info "安装方法: https://eksctl.io/introduction/#installation"
        exit 1
    fi

    # 创建集群配置文件
    cat > /tmp/cluster-config.yaml <<EOF
apiVersion: eksctl.io/v1alpha5
kind: ClusterConfig

metadata:
  name: ${CLUSTER_NAME}
  region: ${REGION}
  version: "${K8S_VERSION}"

# 启用 API_AND_CONFIG_MAP 授权模式（AWS Backup 必需）
accessConfig:
  authenticationMode: API_AND_CONFIG_MAP

iam:
  withOIDC: true

managedNodeGroups:
  - name: ng-1
    instanceType: ${NODE_TYPE}
    desiredCapacity: ${NODE_COUNT}
    minSize: ${NODE_COUNT}
    maxSize: $((NODE_COUNT + 2))
    volumeSize: 50
    labels:
      role: worker
    tags:
      k8s.io/cluster-autoscaler/enabled: "true"
      k8s.io/cluster-autoscaler/${CLUSTER_NAME}: "owned"

# 启用 CloudWatch 日志（用于调试）
cloudWatch:
  clusterLogging:
    enableTypes:
      - audit
      - authenticator
      - controllerManager
EOF

    eksctl create cluster -f /tmp/cluster-config.yaml

    log_success "集群创建完成"

    # 等待集群就绪
    wait_for_cluster_active "$CLUSTER_NAME" 600
}

enable_managed_addons() {
    # 启用 EBS CSI Driver
    log_info "启用 EBS CSI Driver 托管 Add-on..."

    if aws eks describe-addon \
        --cluster-name "$CLUSTER_NAME" \
        --addon-name aws-ebs-csi-driver \
        --region "$REGION" &> /dev/null; then
        log_info "EBS CSI Driver 已存在"
    else
        # 创建 IAM 服务账户
        eksctl create iamserviceaccount \
            --cluster="$CLUSTER_NAME" \
            --region="$REGION" \
            --namespace=kube-system \
            --name=ebs-csi-controller-sa \
            --attach-policy-arn=arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy \
            --approve \
            --override-existing-serviceaccounts

        # 启用 Add-on
        aws eks create-addon \
            --cluster-name "$CLUSTER_NAME" \
            --addon-name aws-ebs-csi-driver \
            --region "$REGION" \
            --resolve-conflicts OVERWRITE

        wait_for_addon_active "$CLUSTER_NAME" "aws-ebs-csi-driver" 300
    fi

    # 启用 EFS CSI Driver
    log_info "启用 EFS CSI Driver 托管 Add-on..."

    if aws eks describe-addon \
        --cluster-name "$CLUSTER_NAME" \
        --addon-name aws-efs-csi-driver \
        --region "$REGION" &> /dev/null; then
        log_info "EFS CSI Driver 已存在"
    else
        # 创建 IAM 服务账户
        eksctl create iamserviceaccount \
            --cluster="$CLUSTER_NAME" \
            --region="$REGION" \
            --namespace=kube-system \
            --name=efs-csi-controller-sa \
            --attach-policy-arn=arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy \
            --approve \
            --override-existing-serviceaccounts

        # 启用 Add-on
        aws eks create-addon \
            --cluster-name "$CLUSTER_NAME" \
            --addon-name aws-efs-csi-driver \
            --region "$REGION" \
            --resolve-conflicts OVERWRITE

        wait_for_addon_active "$CLUSTER_NAME" "aws-efs-csi-driver" 300
    fi

    log_success "托管 Add-on 启用完成"
}

deploy_test_workloads() {
    log_info "部署测试工作负载..."

    # 应用测试工作负载 YAML
    kubectl apply -f "$SCRIPT_DIR/../test-workloads/namespace.yaml" || true
    kubectl apply -f "$SCRIPT_DIR/../test-workloads/statefulset-ebs.yaml"
    kubectl apply -f "$SCRIPT_DIR/../test-workloads/deployment-efs.yaml"

    log_info "等待 Pod 就绪..."
    sleep 30

    # 验证 Pod 状态
    verify_pod_status "test" 300

    log_success "测试工作负载部署完成"
}

deploy_karpenter() {
    log_info "部署 Karpenter..."

    # 检查 Helm 是否安装
    if ! command -v helm &> /dev/null; then
        log_warning "Helm 未安装,跳过 Karpenter 部署"
        log_info "可以稍后运行: ./scripts/04-install-karpenter.sh $CLUSTER_NAME"
        return 0
    fi

    # 使用 Karpenter 安装脚本
    "$SCRIPT_DIR/04-install-karpenter.sh" "$CLUSTER_NAME" "$REGION"

    # 应用 NodePool CR
    kubectl apply -f "$SCRIPT_DIR/../test-workloads/karpenter-nodepool.yaml"

    log_success "Karpenter 部署完成"
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
