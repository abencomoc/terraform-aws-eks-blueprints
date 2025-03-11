locals {

  azs = slice(data.aws_availability_zones.available.names, 0, 2)

  # Routable Private subnets
  # e.g., var.vpc_cidr = "10.1.0.0/24" => output: ["10.1.0.0/26", "10.1.0.64/26"] => 64-2 = 62 usable IPs per subnet/AZ
  routable_private_subnets = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 2, k)]
  # Routable Public subnets with NAT Gateway and Internet Gateway
  # e.g., var.vpc_cidr = "10.1.0.0/24" => output: ["10.1.0.128/26", "10.1.0.192/26"] => 64-2 = 62 usable IPs per subnet/AZ
  routable_public_subnets = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 2, k + 2)]
  # RFC6598 range 100.64.0.0/16 for EKS Data Plane for two subnets(32768 IPs per Subnet) across two AZs for EKS Control Plane ENI + Nodes + Pods
  # e.g., var.secondary_cidr_blocks = "100.64.0.0/16" => output: ["100.64.0.0/17", "100.64.128.0/17"] => 32768-2 = 32766 usable IPs per subnet/AZ
  non_routable_private_subnets = [for k, v in local.azs : cidrsubnet(element(var.secondary_cidr_blocks, 0), 1, k)]
}

locals {

  # After VPC is created, get private subnet IDs from primary vs secondary CIDR
  routable_private_subnet_ids     = compact([for subnet_id, cidr_block in zipmap(module.vpc.private_subnets, module.vpc.private_subnets_cidr_blocks) : substr(cidr_block, 0, 3) == "10." ? subnet_id : null])
  non_routable_private_subnet_ids = compact([for subnet_id, cidr_block in zipmap(module.vpc.private_subnets, module.vpc.private_subnets_cidr_blocks) : substr(cidr_block, 0, 4) == "100." ? subnet_id : null])

  # Tag EksAutoModeCustomNodes true/false is used to select what subnet to use for deploying custom NodePool nodes
  routable_private_subnet_tags = {
    "Type"                            = "routable"
    "kubernetes.io/role/internal-elb" = 1
    "EksAutoModeCustomNodes"          = "false"
  }

  non_routable_private_subnet_tags = {
    "Type"                   = "non-routable"
    "EksAutoModeCustomNodes" = "true"
  }
}

#---------------------------------------------------------------
# VPC
#---------------------------------------------------------------
# WARNING: This VPC module includes the creation of an Internet Gateway and NAT Gateway, which simplifies cluster deployment and testing, primarily intended for sandbox accounts.
# IMPORTANT: For preprod and prod use cases, it is crucial to consult with your security team and AWS architects to design a private infrastructure solution that aligns with your security requirements

module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "~> 5.19"

  name = local.name
  cidr = var.vpc_cidr
  azs  = local.azs

  # Secondary CIDR block attached to VPC for EKS Control Plane ENI + Nodes + Pods
  secondary_cidr_blocks = var.secondary_cidr_blocks

  # 1/ EKS Data Plane secondary CIDR blocks for two subnets across two AZs for EKS Control Plane ENI + Nodes + Pods
  # 2/ Two private Subnets with RFC1918 private IPv4 address range for Private NAT + NLB + Airflow + EC2 Jumphost etc.
  private_subnets = concat(
    local.routable_private_subnets,
    local.non_routable_private_subnets
  )

  # ------------------------------
  # Optional Public Subnets for NAT and IGW for PoC/Dev/Test environments
  # Public Subnets can be disabled while deploying to Production and use Private NAT + TGW in routable private subnets
  public_subnets     = local.routable_public_subnets
  enable_nat_gateway = true
  single_nat_gateway = true
  #-------------------------------

  public_subnet_tags = {}

  private_subnet_tags = {}

  tags = local.tags
}

# Tag routable subnets
resource "aws_ec2_tag" "routable_private_subnet_tags" {
  for_each = {
    for pair in setproduct(local.routable_private_subnet_ids, keys(local.routable_private_subnet_tags)) :
    "${pair[0]}:${pair[1]}" => {
      subnet_id = pair[0]
      key       = pair[1]
      value     = local.routable_private_subnet_tags[pair[1]]
    }
  }

  resource_id = each.value.subnet_id
  key         = each.value.key
  value       = each.value.value

  depends_on = [
    module.vpc
  ]
}

# Tag non_routable subnets
resource "aws_ec2_tag" "non_routable_private_subnet_tags" {
  for_each = {
    for pair in setproduct(local.non_routable_private_subnet_ids, keys(local.non_routable_private_subnet_tags)) :
    "${pair[0]}:${pair[1]}" => {
      subnet_id = pair[0]
      key       = pair[1]
      value     = local.non_routable_private_subnet_tags[pair[1]]
    }
  }

  resource_id = each.value.subnet_id
  key         = each.value.key
  value       = each.value.value

  depends_on = [
    module.vpc
  ]
}

module "vpc_endpoints_sg" {
  source  = "terraform-aws-modules/security-group/aws"
  version = "~> 5.0"

  create = var.enable_vpc_endpoints

  name        = "${local.name}-vpc-endpoints"
  description = "Security group for VPC endpoint access"
  vpc_id      = module.vpc.vpc_id

  ingress_with_cidr_blocks = [
    {
      rule        = "https-443-tcp"
      description = "VPC CIDR HTTPS"
      cidr_blocks = join(",", module.vpc.private_subnets_cidr_blocks)
    },
  ]

  egress_with_cidr_blocks = [
    {
      rule        = "https-443-tcp"
      description = "All egress HTTPS"
      cidr_blocks = "0.0.0.0/0"
    },
  ]

  tags = local.tags
}

module "vpc_endpoints" {
  source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version = "~> 5.0"

  create = var.enable_vpc_endpoints

  vpc_id             = module.vpc.vpc_id
  security_group_ids = [module.vpc_endpoints_sg.security_group_id]

  endpoints = merge({
    s3 = {
      service         = "s3"
      service_type    = "Gateway"
      route_table_ids = module.vpc.private_route_table_ids
      tags = {
        Name = "${local.name}-s3"
      }
    }
    },
    { for service in toset(["autoscaling", "ecr.api", "ecr.dkr", "ec2", "ec2messages", "elasticloadbalancing", "sts", "kms", "logs", "ssm", "ssmmessages"]) :
      replace(service, ".", "_") =>
      {
        service = service
        subnet_ids          = local.routable_private_subnet_ids
        private_dns_enabled = true
        tags                = { Name = "${local.name}-${service}" }
      }
  })

  tags = local.tags
}

