EKS blueprint to deploy EKS AutoMode cluster with custom Nodepools and making use of the non-routable ip address space (RFC 6598 )

**Main features**
- Deploy EKS AutoMode custom NodeClass and custom NodePool optimized for different use cases: compute, memory, graviton.
- Deploys default EBS storageclass and ALB ingressclass.
- Deploys EKS nodes and pods in VPC secondary CIDR range (RFC 6598, non-routable, 100.64.0.0/16), which resolves IP shortage issues in private IP range (routable between VPC and on-prem, RFC 1918).
- Control whether are placed in routable or non-routable subnets per custom NodeClass.
- Control whether to place EKS cluster ENIs in routable or non-routable private subnets
	- EKS cluster ENIs in private routable subnets allows cluster access from on-prem and connected VPCs.
- Deploys observability addons such as aws-observability, fluent-bit, prometheus, grafana, metrics-server
