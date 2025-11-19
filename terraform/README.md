# Terraform 配置 - 基础设施资源

创建 EKS 测试所需的基础设施资源。

## 📦 创建的资源

- **VPC**: 包含 3 个可用区
  - 3 个公有子网
  - 3 个私有子网
  - 1 个 NAT 网关 (成本优化)

- **IAM 角色** (使用 Pod Identity):
  - EKS 集群角色
  - EKS 节点角色
  - EBS CSI Driver 角色
  - EFS CSI Driver 角色
  - Karpenter Controller 角色
  - Karpenter 节点角色

- **EFS 文件系统**: 用于测试持久化存储

- **安全组**: EFS 访问控制

## 🎯 设计理念

**Terraform** → 创建长期基础设施
**eksctl** → 管理 EKS 集群生命周期

这种分离架构的优势:
- ✅ 可以快速删除/重建集群而保留 VPC
- ✅ 测试不同 Kubernetes 版本更方便
- ✅ 符合真实生产环境的实践
- ✅ 成本更低 (只在需要时创建集群)

## 🚀 使用方法

### 1. 初始化

```bash
cd /home/ubuntu/aws-backup-test/terraform
terraform init
```

### 2. 查看计划

```bash
terraform plan
```

### 3. 创建资源

```bash
terraform apply -auto-approve
```

**预计时间**: 5-7 分钟

### 4. 查看输出

```bash
terraform output
```

**重要输出**:
- `vpc_id` - VPC ID
- `private_subnet_ids` - 私有子网 IDs
- `public_subnet_ids` - 公有子网 IDs
- `cluster_role_arn` - EKS 集群 IAM 角色
- `node_role_arn` - EKS 节点 IAM 角色
- `ebs_csi_role_arn` - EBS CSI Driver IAM 角色
- `efs_csi_role_arn` - EFS CSI Driver IAM 角色
- `karpenter_controller_role_arn` - Karpenter Controller IAM 角色
- `efs_filesystem_id` - EFS 文件系统 ID

## ⚙️ 自定义配置

创建 `terraform.tfvars` 文件:

```hcl
aws_region   = "us-west-2"
cluster_name = "my-test-cluster"
vpc_cidr     = "10.0.0.0/16"

tags = {
  Project     = "EKS-Backup-Testing"
  Environment = "Test"
  Owner       = "your-name"
}
```

然后应用:

```bash
terraform apply -var-file="terraform.tfvars"
```

## 🔗 与 eksctl 集成

Terraform 创建基础设施后,使用 eksctl 创建集群:

```bash
# 1. 生成 eksctl 配置 (自动读取 Terraform 输出)
cd /home/ubuntu/aws-backup-test
./eksctl-config/export-tf-outputs.sh 1.32

# 2. 查看生成的配置
cat eksctl-config/cluster-generated.yaml

# 3. 创建集群
eksctl create cluster -f eksctl-config/cluster-generated.yaml
```

## 💰 成本估算

### 基础设施 (测试期间)
- VPC: 免费
- NAT 网关: ~$0.045/小时
- EFS: ~$0.30/GB-月 (测试数据很小)

**4 小时测试**: 约 $0.20

### 如何节省成本

1. **测试完立即清理**:
```bash
terraform destroy -auto-approve
```

2. **保留基础设施,仅删除集群**:
```bash
# 只删除 EKS 集群
eksctl delete cluster --name <集群名称>

# VPC 和 IAM 角色保留,下次测试可复用
```

## 🧹 清理资源

### 完全清理

```bash
# 1. 先删除 EKS 集群
eksctl delete cluster --name $(terraform output -raw cluster_name) --region us-west-2

# 2. 再删除基础设施
terraform destroy -auto-approve
```

### 保留基础设施

```bash
# 只删除 EKS 集群
eksctl delete cluster --name <集群名称> --region us-west-2

# Terraform 资源保留,下次可快速创建新集群
```

## 📝 输出说明

| 输出名称 | 用途 | 使用者 |
|---------|------|--------|
| `vpc_id` | VPC 标识 | eksctl |
| `private_subnet_ids` | 工作节点子网 | eksctl |
| `public_subnet_ids` | 负载均衡器子网 | eksctl |
| `cluster_role_arn` | 集群 IAM 角色 | eksctl |
| `node_role_arn` | 节点 IAM 角色 | eksctl |
| `ebs_csi_role_arn` | EBS CSI Driver 角色 | Pod Identity |
| `efs_csi_role_arn` | EFS CSI Driver 角色 | Pod Identity |
| `karpenter_controller_role_arn` | Karpenter 角色 | Pod Identity |
| `efs_filesystem_id` | EFS 文件系统 ID | 测试工作负载 |

## 🔧 故障排查

### 问题: Terraform apply 失败

**检查**:
```bash
# 验证 AWS 凭证
aws sts get-caller-identity

# 检查区域配额
aws service-quotas list-service-quotas \
  --service-code vpc \
  --region us-west-2
```

### 问题: 输出为空

**解决**:
```bash
# 查看 Terraform 状态
terraform show

# 强制刷新状态
terraform refresh
```

### 问题: VPC 限制

AWS 账户默认每个区域最多 5 个 VPC。

**解决**:
```bash
# 查看当前 VPC 数量
aws ec2 describe-vpcs --region us-west-2 --query 'length(Vpcs)'

# 删除不需要的 VPC 或申请配额提升
```

## 📖 相关文档

- [完整测试指南](../测试指南.md)
- [主 README](../README.md)
- [eksctl 配置](../eksctl-config/)

## 🎯 下一步

创建基础设施后,返回主目录继续测试:

```bash
cd /home/ubuntu/aws-backup-test
# 查看测试指南.md 继续操作
```
