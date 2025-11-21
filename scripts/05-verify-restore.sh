#!/bin/bash
# 05-verify-restore.sh - 验证恢复后的集群状态

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
    log_info "验证 EKS 集群恢复"
    log_info "=========================================="

    check_prerequisites
    check_aws_credentials

    log_info "集群名称: $CLUSTER_NAME"
    log_info "区域: $REGION"

    # 配置 kubectl
    configure_kubectl "$CLUSTER_NAME" "$REGION"

    # 执行验证
    local all_passed=true

    log_info "步骤 1/11: 验证集群版本..."
    verify_cluster_version_info || all_passed=false

    log_info "步骤 2/11: 验证节点状态..."
    verify_nodes || all_passed=false

    log_info "步骤 3/11: 验证托管 Add-on..."
    verify_managed_addons || all_passed=false

    log_info "步骤 4/11: 验证命名空间..."
    verify_namespaces || all_passed=false

    log_info "步骤 5/11: 验证 Deployments..."
    verify_deployments || all_passed=false

    log_info "步骤 6/11: 验证 StatefulSets..."
    verify_statefulsets || all_passed=false

    log_info "步骤 7/11: 验证 StorageClass..."
    verify_storageclasses || all_passed=false

    log_info "步骤 8/11: 验证 PVC 状态..."
    verify_pvcs || all_passed=false

    log_info "步骤 9/11: 验证 Karpenter CRD 和 CR..."
    verify_karpenter || all_passed=false

    log_info "步骤 10/11: 验证数据完整性..."
    verify_data_integrity || all_passed=false

    log_info "步骤 11/11: 生成验证报告..."
    generate_verification_report

    if [ "$all_passed" = true ]; then
        log_success "=========================================="
        log_success "所有验证通过!"
        log_success "=========================================="
        return 0
    else
        log_warning "=========================================="
        log_warning "部分验证未通过,请查看详细报告"
        log_warning "=========================================="
        return 1
    fi
}

verify_cluster_version_info() {
    log_info "检查集群版本..."

    local version=$(aws eks describe-cluster \
        --name "$CLUSTER_NAME" \
        --region "$REGION" \
        --query 'cluster.version' \
        --output text)

    log_info "  Kubernetes 版本: $version"

    kubectl version --short

    log_success "  ✓ 集群版本验证通过"
    return 0
}

verify_nodes() {
    log_info "检查节点状态..."

    local node_count=$(kubectl get nodes --no-headers | wc -l)
    log_info "  节点数量: $node_count"

    if [ "$node_count" -eq 0 ]; then
        log_error "  ✗ 没有可用节点"
        return 1
    fi

    kubectl get nodes

    # 检查节点是否都是 Ready 状态
    local not_ready=$(kubectl get nodes -o json | jq -r '.items[] | select(.status.conditions[] | select(.type=="Ready" and .status!="True")) | .metadata.name' | wc -l)

    if [ "$not_ready" -gt 0 ]; then
        log_warning "  ⚠ 有 $not_ready 个节点未就绪"
        kubectl get nodes | grep NotReady
        return 1
    fi

    log_success "  ✓ 所有节点就绪"
    return 0
}

verify_managed_addons() {
    log_info "检查托管 Add-on..."

    local addons=("aws-ebs-csi-driver" "aws-efs-csi-driver")
    local all_active=true

    for addon in "${addons[@]}"; do
        if aws eks describe-addon \
            --cluster-name "$CLUSTER_NAME" \
            --addon-name "$addon" \
            --region "$REGION" &> /dev/null; then
            local status=$(aws eks describe-addon \
                --cluster-name "$CLUSTER_NAME" \
                --addon-name "$addon" \
                --region "$REGION" \
                --query 'addon.status' \
                --output text)

            if [ "$status" = "ACTIVE" ]; then
                log_success "  ✓ $addon: $status"

                # 检查 CSI driver pods 运行状态
                local pod_label
                if [[ "$addon" == *"ebs"* ]]; then
                    pod_label="app.kubernetes.io/name=aws-ebs-csi-driver"
                else
                    pod_label="app.kubernetes.io/name=aws-efs-csi-driver"
                fi

                local running_pods=$(kubectl get pods -n kube-system -l "$pod_label" \
                    -o json 2>/dev/null | \
                    jq -r '.items[] | select(.status.phase == "Running") | .metadata.name' | wc -l)

                if [ "$running_pods" -gt 0 ]; then
                    log_success "    ✓ CSI driver pods 运行正常 ($running_pods 个)"
                else
                    log_warning "    ⚠ CSI driver pods 未运行"
                    kubectl get pods -n kube-system -l "$pod_label"
                    all_active=false
                fi
            else
                log_warning "  ⚠ $addon: $status"
                all_active=false
            fi
        else
            log_warning "  ⚠ $addon: 未安装"
            all_active=false
        fi
    done

    if [ "$all_active" = true ]; then
        return 0
    else
        return 1
    fi
}

verify_namespaces() {
    log_info "检查命名空间..."

    kubectl get namespaces

    # 检查测试命名空间
    local expected_namespaces=("test" "karpenter")
    for ns in "${expected_namespaces[@]}"; do
        if kubectl get namespace "$ns" &> /dev/null; then
            log_success "  ✓ 命名空间存在: $ns"
        else
            log_warning "  ⚠ 命名空间不存在: $ns"
        fi
    done

    return 0
}

verify_deployments() {
    log_info "检查 Deployments..."

    local deployment_count=$(kubectl get deployments --all-namespaces --no-headers 2>/dev/null | wc -l)
    log_info "  Deployment 数量: $deployment_count"

    kubectl get deployments --all-namespaces

    # 检查所有 Deployments 是否就绪
    local not_ready=$(kubectl get deployments --all-namespaces -o json | \
        jq -r '.items[] | select(.status.readyReplicas != .status.replicas) | "\(.metadata.namespace)/\(.metadata.name)"' | wc -l)

    if [ "$not_ready" -gt 0 ]; then
        log_warning "  ⚠ 有 $not_ready 个 Deployment 未就绪"
        return 1
    fi

    log_success "  ✓ 所有 Deployments 就绪"
    return 0
}

verify_statefulsets() {
    log_info "检查 StatefulSets..."

    local sts_count=$(kubectl get statefulsets --all-namespaces --no-headers 2>/dev/null | wc -l)
    log_info "  StatefulSet 数量: $sts_count"

    if [ "$sts_count" -gt 0 ]; then
        kubectl get statefulsets --all-namespaces

        # 检查所有 StatefulSets 是否就绪
        local not_ready=$(kubectl get statefulsets --all-namespaces -o json | \
            jq -r '.items[] | select(.status.readyReplicas != .status.replicas) | "\(.metadata.namespace)/\(.metadata.name)"' | wc -l)

        if [ "$not_ready" -gt 0 ]; then
            log_warning "  ⚠ 有 $not_ready 个 StatefulSet 未就绪"
            return 1
        fi

        log_success "  ✓ 所有 StatefulSets 就绪"
    else
        log_info "  没有 StatefulSet"
    fi

    return 0
}

verify_storageclasses() {
    log_info "检查 StorageClass..."

    local sc_count=$(kubectl get storageclasses --no-headers 2>/dev/null | wc -l)
    log_info "  StorageClass 数量: $sc_count"

    if [ "$sc_count" -eq 0 ]; then
        log_warning "  ⚠ 没有 StorageClass"
        return 1
    fi

    kubectl get storageclasses

    # 检查必需的 StorageClass
    local required_scs=("ebs-sc")
    local all_found=true

    for sc in "${required_scs[@]}"; do
        if kubectl get storageclass "$sc" &> /dev/null; then
            log_success "  ✓ StorageClass 存在: $sc"

            # 显示详细信息
            local provisioner=$(kubectl get storageclass "$sc" -o jsonpath='{.provisioner}')
            local binding_mode=$(kubectl get storageclass "$sc" -o jsonpath='{.volumeBindingMode}')
            log_info "    Provisioner: $provisioner"
            log_info "    Binding Mode: $binding_mode"
        else
            log_warning "  ⚠ StorageClass 不存在: $sc"
            all_found=false
        fi
    done

    if [ "$all_found" = true ]; then
        log_success "  ✓ 所有必需的 StorageClass 已创建"
        return 0
    else
        log_error "  ✗ 部分 StorageClass 缺失"
        log_info "  提示: 运行 'kubectl apply -f test-workloads/statefulset-ebs.yaml' 创建 StorageClass"
        return 1
    fi
}

verify_pvcs() {
    log_info "检查 PVC 状态..."

    local pvc_count=$(kubectl get pvc --all-namespaces --no-headers 2>/dev/null | wc -l)
    log_info "  PVC 数量: $pvc_count"

    if [ "$pvc_count" -eq 0 ]; then
        log_info "  没有 PVC"
        return 0
    fi

    kubectl get pvc --all-namespaces

    # 检查 PVC 绑定状态
    local pending_pvcs=$(kubectl get pvc --all-namespaces -o json | \
        jq -r '.items[] | select(.status.phase != "Bound") | "\(.metadata.namespace)/\(.metadata.name)"')
    local pending_count=$(echo "$pending_pvcs" | grep -c . || echo 0)

    if [ "$pending_count" -gt 0 ]; then
        log_warning "  ⚠ 有 $pending_count 个 PVC 未绑定"
        kubectl get pvc --all-namespaces | grep -v Bound

        # 显示每个 pending PVC 的详细事件
        log_info "  显示未绑定 PVC 的详细事件:"
        while IFS= read -r pvc_ref; do
            if [ -n "$pvc_ref" ]; then
                local namespace=$(echo "$pvc_ref" | cut -d'/' -f1)
                local pvc_name=$(echo "$pvc_ref" | cut -d'/' -f2)

                log_info "  --- PVC: $pvc_ref ---"
                kubectl describe pvc "$pvc_name" -n "$namespace" | grep -A 10 "Events:" || \
                    log_warning "    无事件信息"

                # 检查是否是 StorageClass 问题
                local sc_name=$(kubectl get pvc "$pvc_name" -n "$namespace" -o jsonpath='{.spec.storageClassName}')
                if ! kubectl get storageclass "$sc_name" &> /dev/null; then
                    log_error "    ✗ StorageClass 不存在: $sc_name"
                fi
            fi
        done <<< "$pending_pvcs"

        return 1
    fi

    log_success "  ✓ 所有 PVC 已绑定"
    return 0
}

verify_karpenter() {
    log_info "检查 Karpenter..."

    # 检查 Karpenter CRD
    local crds=("nodepools.karpenter.sh" "ec2nodeclasses.karpenter.k8s.aws")
    local crd_found=0

    for crd in "${crds[@]}"; do
        if kubectl get crd "$crd" &> /dev/null; then
            log_success "  ✓ CRD 存在: $crd"
            crd_found=$((crd_found + 1))
        else
            log_warning "  ⚠ CRD 不存在: $crd"
        fi
    done

    # 检查 Karpenter Controller
    if kubectl get deployment karpenter -n karpenter &> /dev/null; then
        log_info "  检查 Karpenter Controller 状态..."
        kubectl get pods -n karpenter

        local ready=$(kubectl get deployment karpenter -n karpenter -o json | \
            jq -r '.status.readyReplicas // 0')
        local desired=$(kubectl get deployment karpenter -n karpenter -o json | \
            jq -r '.status.replicas // 0')

        if [ "$ready" -eq "$desired" ] && [ "$ready" -gt 0 ]; then
            log_success "  ✓ Karpenter Controller 运行正常 ($ready/$desired)"
        else
            log_warning "  ⚠ Karpenter Controller 未就绪 ($ready/$desired)"
        fi
    else
        log_warning "  ⚠ Karpenter Controller 未安装"
        log_info "  运行: ./scripts/04-install-karpenter.sh $CLUSTER_NAME"
    fi

    # 检查 NodePool CR
    local nodepool_count=$(kubectl get nodepools -n karpenter --no-headers 2>/dev/null | wc -l)
    if [ "$nodepool_count" -gt 0 ]; then
        log_success "  ✓ 发现 $nodepool_count 个 NodePool CR"
        kubectl get nodepools -n karpenter
    else
        log_warning "  ⚠ 未发现 NodePool CR"
    fi

    if [ "$crd_found" -eq ${#crds[@]} ]; then
        return 0
    else
        return 1
    fi
}

verify_data_integrity() {
    log_info "检查数据完整性..."

    # 检查 StatefulSet 数据
    if kubectl get statefulset mysql-statefulset -n test &> /dev/null; then
        if kubectl wait --for=condition=ready pod/mysql-statefulset-0 -n test --timeout=60s 2>/dev/null; then
            log_info "  检查 MySQL StatefulSet 数据..."

            # 检查测试文件是否存在
            if kubectl exec -n test mysql-statefulset-0 -- test -f /data/test_file.txt; then
                local content=$(kubectl exec -n test mysql-statefulset-0 -- cat /data/test_file.txt)
                log_success "  ✓ 测试文件存在: /data/test_file.txt"
                log_info "    内容: $content"
            else
                log_warning "  ⚠ 测试文件不存在"
                return 1
            fi

            if kubectl exec -n test mysql-statefulset-0 -- test -f /data/timestamp.txt; then
                local timestamp=$(kubectl exec -n test mysql-statefulset-0 -- cat /data/timestamp.txt)
                log_success "  ✓ 时间戳文件存在"
                log_info "    $timestamp"
            fi

            log_success "  ✓ 数据完整性验证通过"
            return 0
        else
            log_warning "  ⚠ Pod 未就绪,跳过数据验证"
            return 1
        fi
    else
        log_info "  没有 StatefulSet,跳过数据验证"
        return 0
    fi
}

generate_verification_report() {
    local output_dir="/home/ubuntu/aws-backup-test/results/verification-$(date +%Y%m%d-%H%M%S)"
    mkdir -p "$output_dir"

    log_info "生成验证报告..."

    # 收集集群信息
    kubectl get all --all-namespaces > "$output_dir/all-resources.txt" 2>&1
    kubectl get pvc --all-namespaces > "$output_dir/pvcs.txt" 2>&1
    kubectl get crd | grep karpenter > "$output_dir/karpenter-crds.txt" 2>&1
    kubectl get nodepools -n karpenter > "$output_dir/nodepools.txt" 2>&1

    # 生成 Markdown 报告
    cat > "$output_dir/verification-report.md" <<EOF
# EKS 集群恢复验证报告

**集群名称**: $CLUSTER_NAME
**区域**: $REGION
**验证时间**: $(date)
**执行者**: $(whoami)

## 验证结果总结

### 集群基本信息
- Kubernetes 版本: $(kubectl version --short 2>/dev/null | grep Server || echo "N/A")
- 节点数量: $(kubectl get nodes --no-headers | wc -l)
- 命名空间数量: $(kubectl get namespaces --no-headers | wc -l)

### 资源统计
- Deployments: $(kubectl get deployments --all-namespaces --no-headers 2>/dev/null | wc -l)
- StatefulSets: $(kubectl get statefulsets --all-namespaces --no-headers 2>/dev/null | wc -l)
- PVCs: $(kubectl get pvc --all-namespaces --no-headers 2>/dev/null | wc -l)
- Karpenter CRDs: $(kubectl get crd | grep karpenter | wc -l)
- NodePools: $(kubectl get nodepools -n karpenter --no-headers 2>/dev/null | wc -l)

### 托管 Add-on 状态
\`\`\`
$(aws eks list-addons --cluster-name "$CLUSTER_NAME" --region "$REGION" --output table 2>&1)
\`\`\`

### 节点列表
\`\`\`
$(kubectl get nodes 2>&1)
\`\`\`

### PVC 状态
\`\`\`
$(kubectl get pvc --all-namespaces 2>&1)
\`\`\`

### Karpenter 资源
\`\`\`
$(kubectl get nodepools -n karpenter 2>&1)
\`\`\`

---
*报告生成时间: $(date)*
EOF

    log_success "验证报告已保存到: $output_dir/verification-report.md"
    log_info "详细资源信息保存在: $output_dir/"
}

# 执行主函数
main
