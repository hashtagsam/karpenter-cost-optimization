module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "21.29.0"

  name               = local.name
  kubernetes_version = var.kubernetes_version

  # API Endpoint Access
  # The Kubernetes API server is the front door to the whole cluster. Private access lets nodes and pods reach it from inside the VPC 
  # without leaving AWS's network. Public access is needed so kubectl on your laptop works without a VPN, but it is restricted to the CIDRs 
  # you listed (your IP). Any other IP on the internet can't even open a connection. In production you would switch public access off and use a VPN or bastion.

  endpoint_private_access      = true
  endpoint_public_access       = var.endpoint_public_access
  endpoint_public_access_cidrs = var.endpoint_public_access_cidrs

  #########################################
  # Authentication: Who can use the server
  #########################################

  authentication_mode                      = "API"
  enable_cluster_creator_admin_permissions = false

  access_entries = {
    for idx, arn in var.admin_principal_arns : "admin-${idx}" => {
      principal_arn = arn
      policy_associations = {
        cluster_admin = {
          policy_arn   = "arn:${local.partition}:eks::aws:cluster-access-policy/AmazonEKSClusterAdminPolicy"
          access_scope = { type = "cluster" }
        }
      }
    }
  }

  # Encryption and audit logging
  create_kms_key    = true
  encryption_config = { resources = ["secrets"] }

  enabled_log_types                      = ["api", "audit", "authenticator", "controllerManager", "scheduler"]
  cloudwatch_log_group_retention_in_days = var.control_plane_log_retention_days

  deletion_protection = var.deletion_protection

  ##########
  # Add-ons
  ##########
  addons = {
    coredns = {
      most_recent = true
    }
    kube-proxy = {
      most_recent = true
    }
    eks-pod-identity-agent = {
      most_recent    = true
      before_compute = true
    }
    vpc-cni = {
      most_recent    = true
      before_compute = true
      # Enables Kubernetes NetworkPolicy enforcement in the VPC CNI
      configuration_values = jsonencode({
        enableNetworkPolicy = "true"
      })
    }
  }

  # Networking inputs
  vpc_id                   = module.vpc.vpc_id
  subnet_ids               = module.vpc.private_subnets
  control_plane_subnet_ids = module.vpc.intra_subnets

  #################################################
  # Node Group: For Karpenter, kyverner and CoreDNS
  #################################################
  # Karpenter is itself a pod, and it needs somewhere to run before it can create any nodes. 
  # If it ran on nodes it manages, it could consolidate away the node it's running on. 
  # So two small, permanent nodes host Karpenter, CoreDNS and Kyverno; everything else runs on Karpenter's nodes.

  eks_managed_node_groups = {
    system = {
      ami_type       = "BOTTLEROCKET_ARM_64"
      instance_types = var.system_node_instance_types
      capacity_type  = "ON_DEMAND"

      min_size     = 2
      max_size     = 3
      desired_size = 2

      labels = {
        "karpenter.sh/controller" = "true"
        "node-role"               = "system"
      }

      # Only critical add-ons tolerate this taint
      taints = {
        critical_addons = {
          key    = "CriticalAddonsOnly"
          value  = "true"
          effect = "NO_SCHEDULE"
        }
      }

      # IMDSv2 only, and pods cannot reach IMDS (hop limit 1) -> no stealing
      # the node role credentials from inside a container
      metadata_options = {
        http_endpoint               = "enabled"
        http_tokens                 = "required"
        http_put_response_hop_limit = 1
      }

      # Session Manager instead of SSH: no keys, no port 22, fully audited
      iam_role_additional_policies = {
        AmazonSSMManagedInstanceCore = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
      }

      update_config = {
        max_unavailable_percentage = 33
      }
    }
  }

  # Node security group tag: Karpenter's EC2NodeClass discovers the node security group by this tag
  node_security_group_tags = {
    "karpenter.sh/discovery" = local.name
  }
}
