variable "name" {
  description = "Name of the VPC and EKS Cluster"
  type        = string
  default     = "eks-automode-blueprint"
}
variable "region" {
  description = "Region"
  default     = "us-east-1"
  type        = string
}
variable "eks_cluster_version" {
  description = "EKS Cluster version"
  type        = string
  default     = "1.31"
}
variable "tags" {
  description = "Default tags"
  type        = map(string)
  default     = {}
}

# VPC with ~250 IPs (10.1.0.0/24) and 2 AZs
variable "vpc_cidr" {
  description = "VPC CIDR. This should be a valid private (RFC 1918) CIDR range"
  type        = string
  default     = "10.1.0.0/24"
}

# RFC6598 range 100.64.0.0/10
# Note you can only /16 range to VPC. You can add multiples of /16 if required
variable "secondary_cidr_blocks" {
  description = "Secondary CIDR blocks to be attached to VPC"
  type        = list(string)
  default     = ["100.64.0.0/16"]
}

# If true, EKS cluster ENIs are placed in routable private subnets (10.1.0.0/24). Then the cluster is accessible (ex: kubectl) from within the VPC and any network connected to the VPC (ex: on-prem)
# If false, ENIs are placed in non_routable private subnets (100.64.0.0/16). Then the cluster is only accessible (ex: kubectl) from within the VPC. You can create a bastion host in the VPC to connect to the cluster.
variable "routable_cluster_access" {
  description = "Place EKS cluster ENIs in routable private subnets"
  type        = bool
  default     = true
}

variable "enable_vpc_endpoints" {
  description = "Enable VPC Endpoints"
  type        = bool
  default     = true
}

# Cloudwatch Observability addon sends logs and metrics to CloudWatch
variable "enable_cloudwatch_observability" {
  description = "Deploy Cloudwatch Observability addon to enable managed observability in the cluster"
  type        = bool
  default     = false
}
