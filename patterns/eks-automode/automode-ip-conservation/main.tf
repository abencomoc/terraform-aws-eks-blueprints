terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 4.47"
    }
    kubernetes = {
      source  = "hashicorp/kubernetes"
      version = ">= 2.10"
    }
    helm = {
      source  = "hashicorp/helm"
      version = ">= 2.4"
    }
    kubectl = {
      source  = "gavinbunney/kubectl"
      version = ">= 1.14"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.3"
    }
  }
}

provider "aws" {
  region = local.region
}

provider "helm" {
  kubernetes {
    host                   = module.eks.cluster_endpoint
    cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)

    exec {
      api_version = "client.authentication.k8s.io/v1beta1"
      command     = "aws"
      # This requires the awscli to be installed locally where Terraform is executed
      args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name,
      "--region", local.region]
    }
  }
}

provider "kubectl" {
  apply_retry_count      = 30
  host                   = module.eks.cluster_endpoint
  cluster_ca_certificate = base64decode(module.eks.cluster_certificate_authority_data)
  load_config_file       = false

  exec {
    api_version = "client.authentication.k8s.io/v1beta1"
    command     = "aws"
    # This requires the awscli to be installed locally where Terraform is executed
    args = ["eks", "get-token", "--cluster-name", module.eks.cluster_name,
    "--region", local.region]
  }
}

data "aws_availability_zones" "available" {
  # Do not include local zones
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

locals {
  name   = basename(path.cwd)
  region = "us-east-1"

  cluster_version = "1.31"

  vpc_cidr              = "192.168.0.0/24"
  secondary_cidr_blocks = ["100.64.0.0/16"]
  azs                   = slice(data.aws_availability_zones.available.names, 0, 2)

  public_subnets               = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 2, k)]
  routable_private_subnets     = [for k, v in local.azs : cidrsubnet(local.vpc_cidr, 2, k + 2)]
  # non_routable_private_subnets = [for k, v in local.azs : cidrsubnet(element(local.secondary_cidr_blocks, 0), 1, k)]

  routable_private_subnets_ids = compact([for subnet_id, cidr_block in zipmap(module.vpc.private_subnets, module.vpc.private_subnets_cidr_blocks) : substr(cidr_block, 0, 4) == "192." ? subnet_id : null])

  tags = {
    Blueprint  = local.name
    GithubRepo = "github.com/aws-ia/terraform-aws-eks-blueprints"
  }

}

###############################################################
# EKS Cluster
###############################################################

module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "~> 20.34"

  cluster_name    = local.name
  cluster_version = local.cluster_version

  cluster_endpoint_public_access = true

  vpc_id     = module.vpc.vpc_id
  subnet_ids = local.routable_private_subnets_ids

  enable_cluster_creator_admin_permissions = true

  # Enable EKS AutoMode
  cluster_compute_config = {
    enabled    = true
    node_pools = []
  }

  tags = local.tags
}

###############################################################
# Supporting Resources
###############################################################

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.19"

  name                  = local.name
  cidr                  = local.vpc_cidr
  secondary_cidr_blocks = local.secondary_cidr_blocks

  azs            = local.azs
  public_subnets = local.public_subnets
  private_subnets = local.routable_private_subnets

  enable_nat_gateway = true
  single_nat_gateway = true

  public_subnet_tags  = { "kubernetes.io/role/elb" = 1 }
  private_subnet_tags = { "kubernetes.io/role/internal-elb" = 1 }

  # private_subnet_names = concat(
  #   # Names for routable private subnets
  #   [for i, subnet in local.routable_private_subnets : "${local.name}-private-routable-${local.azs[i]}"],
  #   # Names for non-routable private subnets
  #   [for i, subnet in local.non_routable_private_subnets : "${local.name}-private-non-routable-${local.azs[i]}"]
  # )

  tags = local.tags
}

# # Tag private routable private subnets only
# resource "aws_ec2_tag" "private_subnet_internal_elb" {
#   count       = length(local.azs)
#   resource_id = local.routable_private_subnets_ids[count.index]
#   key         = "kubernetes.io/role/internal-elb"
#   value       = "1"
# }

# Create private subnets in each AZ using secondary CIDR
resource "aws_subnet" "private_secondary" {
  count             = length(local.azs)
  vpc_id            = module.vpc.vpc_id
  cidr_block        = cidrsubnet(element(local.secondary_cidr_blocks, 0), 1, count.index)
  availability_zone = local.azs[count.index]

  tags = merge(
    {
      Name = "${local.name}-private-secondary-${local.azs[count.index]}"
    },
    local.tags
  )
}

# Create route table for secondary private subnets
resource "aws_route_table" "private_secondary" {
  vpc_id = module.vpc.vpc_id

  # Route private traffic to the Private NAT Gateway
  route {
    cidr_block     = "192.168.0.0/16"
    nat_gateway_id = aws_nat_gateway.private.id
  }

  # Default route to public NAT gateway
  route {
    cidr_block     = "0.0.0.0/0"
    nat_gateway_id = module.vpc.natgw_ids[0]
  }

  tags = merge(
    {
      Name = "${local.name}-rt-private-secondary"
    },
    local.tags
  )
}

# Associate route table with secondary private subnets
resource "aws_route_table_association" "private_secondary" {
  count          = length(local.azs)
  subnet_id      = aws_subnet.private_secondary[count.index].id
  route_table_id = aws_route_table.private_secondary.id
}

# Create private NAT gateway in the first routable subnet
resource "aws_nat_gateway" "private" {
  subnet_id         = module.vpc.private_subnets[0]
  connectivity_type = "private"

  tags = merge(
    { Name = "${local.name}-private-nat" },
    local.tags
  )
}

# # Add route to private subnets' route tables pointing to your Transit Gateway or VPN Gateway
# resource "aws_route" "private_to_tgw" {
#   count                  = length(module.vpc.private_route_table_ids)
#   route_table_id         = module.vpc.private_route_table_ids[count.index]
#   destination_cidr_block = "192.168.0.0/16"
#   nat_gateway_id         = <Transit Gateway or VPN Gateway>
# }

###############################################################
# Outputs
###############################################################

output "configure_kubectl" {
  description = "Configure kubectl: make sure you're logged in with the correct AWS profile and run the following command to update your kubeconfig"
  value       = "aws eks --region ${local.region} update-kubeconfig --name ${module.eks.cluster_name}"
}