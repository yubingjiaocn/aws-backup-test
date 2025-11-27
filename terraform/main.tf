# Terraform Configuration - Infrastructure Resources for EKS
# This creates VPC, IAM roles, EFS, and security groups
# EKS cluster will be created separately using eksctl

terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

# Data sources
data "aws_availability_zones" "available" {
  state = "available"
}

data "aws_caller_identity" "current" {}

# ============================================
# VPC and Networking
# ============================================

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.0"

  name = "${var.cluster_name}-vpc"
  cidr = var.vpc_cidr

  azs             = data.aws_availability_zones.available.names
  private_subnets = [for k, v in data.aws_availability_zones.available.names : cidrsubnet(var.vpc_cidr, 8, k)]
  public_subnets  = [for k, v in data.aws_availability_zones.available.names : cidrsubnet(var.vpc_cidr, 8, k + 10)]

  enable_nat_gateway   = true
  single_nat_gateway   = true  # Cost optimization for testing
  enable_dns_hostnames = true
  enable_dns_support   = true

  # Tags required for EKS
  public_subnet_tags = {
    "kubernetes.io/role/elb"                    = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb"           = "1"
    "kubernetes.io/cluster/${var.cluster_name}" = "shared"
    "karpenter.sh/discovery"                    = var.cluster_name
  }

  tags = var.tags
}

# ============================================
# EFS File System
# ============================================

resource "aws_efs_file_system" "test" {
  creation_token = "${var.cluster_name}-efs"
  encrypted      = true

  tags = merge(
    var.tags,
    {
      Name = "${var.cluster_name}-efs"
    }
  )
}

resource "aws_efs_mount_target" "test" {
  count = length(module.vpc.private_subnets)

  file_system_id  = aws_efs_file_system.test.id
  subnet_id       = module.vpc.private_subnets[count.index]
  security_groups = [aws_security_group.efs.id]
}

# Security group for EFS
resource "aws_security_group" "efs" {
  name_prefix = "${var.cluster_name}-efs-"
  description = "Security group for EFS mount targets"
  vpc_id      = module.vpc.vpc_id

  ingress {
    description = "NFS from VPC"
    from_port   = 2049
    to_port     = 2049
    protocol    = "tcp"
    cidr_blocks = [var.vpc_cidr]
  }

  egress {
    from_port   = 0
    to_port     = 0
    protocol    = "-1"
    cidr_blocks = ["0.0.0.0/0"]
  }

  tags = merge(
    var.tags,
    {
      Name = "${var.cluster_name}-efs-sg"
    }
  )
}

# ============================================
# IAM Roles - EKS Cluster and Nodes
# ============================================

# EKS Cluster Role
resource "aws_iam_role" "eks_cluster" {
  name = "eksClusterRole-${var.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "eks.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "eks_cluster_policy" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

# EKS Node Role
resource "aws_iam_role" "eks_node" {
  name = "eksNodeRole-${var.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "ec2.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "eks_node_policies" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore"
  ])

  role       = aws_iam_role.eks_node.name
  policy_arn = each.value
}

resource "aws_iam_instance_profile" "eks_node" {
  name = "eksNodeInstanceProfile-${var.cluster_name}"
  role = aws_iam_role.eks_node.name

  tags = var.tags
}

# ============================================
# IAM Roles - EBS CSI Driver (Pod Identity)
# ============================================

resource "aws_iam_role" "ebs_csi" {
  name = "AmazonEKS_EBS_CSI_DriverRole_${var.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com"
      }
      Action = [
        "sts:AssumeRole",
        "sts:TagSession"
      ]
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "ebs_csi" {
  role       = aws_iam_role.ebs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEBSCSIDriverPolicy"
}

# ============================================
# IAM Roles - EFS CSI Driver (Pod Identity)
# ============================================

resource "aws_iam_role" "efs_csi" {
  name = "AmazonEKS_EFS_CSI_DriverRole_${var.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "pods.eks.amazonaws.com"
      }
      Action = [
        "sts:AssumeRole",
        "sts:TagSession"
      ]
    }]
  })

  tags = var.tags
}

resource "aws_iam_role_policy_attachment" "efs_csi" {
  role       = aws_iam_role.efs_csi.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AmazonEFSCSIDriverPolicy"
}

# ============================================
# IAM Role - AWS Backup Service Role
# ============================================

resource "aws_iam_role" "aws_backup" {
  name = "AWSBackupServiceRole-${var.cluster_name}"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Principal = {
        Service = "backup.amazonaws.com"
      }
      Action = "sts:AssumeRole"
    }]
  })

  tags = merge(
    var.tags,
    {
      Description = "Service role for AWS Backup"
    }
  )
}

resource "aws_iam_role_policy_attachment" "aws_backup_policy" {
  role       = aws_iam_role.aws_backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForBackup"
}

resource "aws_iam_role_policy_attachment" "aws_backup_restores_policy" {
  role       = aws_iam_role.aws_backup.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSBackupServiceRolePolicyForRestores"
}

resource "aws_iam_role_policy_attachment" "aws_backup_s3_policy" {
  role       = aws_iam_role.aws_backup.name
  policy_arn = "arn:aws:iam::aws:policy/AWSBackupServiceRolePolicyForS3Backup"
}

# ============================================
# AWS Backup Vault
# ============================================

resource "aws_backup_vault" "main" {
  name = "${var.cluster_name}-backup-vault"

  tags = merge(
    var.tags,
    {
      Name        = "${var.cluster_name}-backup-vault"
      Description = "Backup vault for EKS cluster resources"
    }
  )
}

# ============================================
# Outputs for eksctl
# ============================================

output "vpc_id" {
  description = "VPC ID for eksctl"
  value       = module.vpc.vpc_id
}

output "private_subnet_ids" {
  description = "Private subnet IDs for eksctl"
  value       = module.vpc.private_subnets
}

output "public_subnet_ids" {
  description = "Public subnet IDs for eksctl"
  value       = module.vpc.public_subnets
}

output "cluster_role_arn" {
  description = "EKS Cluster IAM role ARN"
  value       = aws_iam_role.eks_cluster.arn
}

output "node_role_arn" {
  description = "EKS Node IAM role ARN"
  value       = aws_iam_role.eks_node.arn
}

output "node_instance_profile_arn" {
  description = "EKS Node instance profile ARN"
  value       = aws_iam_instance_profile.eks_node.arn
}

output "ebs_csi_role_arn" {
  description = "EBS CSI Driver IAM role ARN"
  value       = aws_iam_role.ebs_csi.arn
}

output "efs_csi_role_arn" {
  description = "EFS CSI Driver IAM role ARN"
  value       = aws_iam_role.efs_csi.arn
}

output "efs_filesystem_id" {
  description = "EFS filesystem ID"
  value       = aws_efs_file_system.test.id
}

output "efs_security_group_id" {
  description = "EFS security group ID"
  value       = aws_security_group.efs.id
}

output "cluster_name" {
  description = "Cluster name to use with eksctl"
  value       = var.cluster_name
}

output "aws_region" {
  description = "AWS region"
  value       = var.aws_region
}

output "aws_backup_role_arn" {
  description = "AWS Backup service role ARN"
  value       = aws_iam_role.aws_backup.arn
}

output "backup_vault_name" {
  description = "AWS Backup vault name"
  value       = aws_backup_vault.main.name
}

output "backup_vault_arn" {
  description = "AWS Backup vault ARN"
  value       = aws_backup_vault.main.arn
}
