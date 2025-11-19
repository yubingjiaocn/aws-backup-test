# Terraform Variables - Infrastructure Resources

variable "aws_region" {
  description = "AWS 区域"
  type        = string
  default     = "us-west-2"
}

variable "cluster_name" {
  description = "EKS 集群名称"
  type        = string
  default     = "eks-backup-test-source"
}

variable "vpc_cidr" {
  description = "VPC CIDR 块"
  type        = string
  default     = "10.0.0.0/16"
}

variable "tags" {
  description = "资源标签"
  type        = map(string)
  default = {
    Project     = "AWS-Backup-EKS-Testing"
    ManagedBy   = "Terraform"
    Environment = "Test"
  }
}
