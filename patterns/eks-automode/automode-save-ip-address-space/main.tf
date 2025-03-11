provider "aws" {
  region = local.region

  // This is necessary so that tags required for eks can be applied to the vpc without changes to the vpc wiping them out.
  // https://registry.terraform.io/providers/hashicorp/aws/latest/docs/guides/resource-tagging
  ignore_tags {
    key_prefixes = ["kubernetes.io/","EksAutoModeCustomNodes","Type"]
  }
}

# ECR always authenticates with `us-east-1` region
# Docs -> https://docs.aws.amazon.com/AmazonECR/latest/public/public-registries.html
provider "aws" {
  alias  = "ecr"
  region = "us-east-1"
}

provider "kubernetes" {
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  token                  = data.aws_eks_cluster_auth.this.token
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
    token                  = data.aws_eks_cluster_auth.this.token
  }
}

provider "kubectl" {
  apply_retry_count      = 30
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  load_config_file       = false
  token                  = data.aws_eks_cluster_auth.this.token
}

data "aws_eks_cluster_auth" "this" {
  name = module.eks.cluster_name
}

data "aws_ecrpublic_authorization_token" "token" {
  provider = aws.ecr
}

# This ECR "registry_id" number refers to the AWS account ID for us-east-1 region
# if you are using a different region, make sure to change it, you can get the account from the link below
# https://docs.aws.amazon.com/emr/latest/EMR-on-EKS-DevelopmentGuide/docker-custom-images-tag.html
data "aws_ecr_authorization_token" "token" {
  registry_id = "755674844232"
}

data "aws_caller_identity" "current" {}
data "aws_availability_zones" "available" {}
data "aws_region" "current" {}
data "aws_partition" "current" {}

locals {
  name   = var.name
  region = var.region

  tags = merge(var.tags, {
    Blueprint  = local.name
    GithubRepo = "github.com/aws-ia/terraform-aws-eks-blueprints"
  })
}

#---------------------------------------------------------------
# EKS Cluster
#---------------------------------------------------------------

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.34"

  cluster_name    = local.name
  cluster_version = var.eks_cluster_version

  # if true, Your cluster API server is accessible from the internet. You can, optionally, limit the CIDR blocks that can access the public endpoint.
  #WARNING: Avoid using this option (cluster_endpoint_public_access = true) in preprod or prod accounts. This feature is designed for sandbox accounts, simplifying cluster deployment and testing.
  # Alternatively, create a bastion host in the same VPC as the cluster to access the cluster API server over a private connection
  cluster_endpoint_public_access = true

  vpc_id     = module.vpc.vpc_id

  # If true, EKS cluster ENIs are placed in routable private subnets (10.1.0.0/24). 
  # If false, ENIs are placed in non_routable private subnets (100.64.0.0/16)
  subnet_ids = var.routable_cluster_access ? local.routable_private_subnet_ids : local.non_routable_private_subnet_ids

  enable_cluster_creator_admin_permissions = true

  # Enable EKS AutoMode
  cluster_compute_config = {
    enabled    = true
    node_pools = []
  }

  # cluster_addons = {
  #   metrics-server = {}
  # }

  #---------------------------------------
  # Note: This can further restricted to specific required for each Add-on and your application
  #---------------------------------------
  # Extend node-to-node security group rules. SG used by custom nodepools
  # node_security_group_additional_rules = {
  #   ingress_self_all = {
  #     description = "Node to node all ports/protocols"
  #     protocol    = "-1"
  #     from_port   = 0
  #     to_port     = 0
  #     type        = "ingress"
  #     self        = true
  #   }
  # }

  tags = local.tags
}
