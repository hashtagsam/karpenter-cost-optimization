module "vpc" {
  source  = "terraform-aws-modules/vpc/aws"
  version = "6.7.3"

  name = local.name
  cidr = var.vpc_cidr
  azs  = local.azs

  private_subnets = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 4, k)]
  public_subnets  = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 48)]
  intra_subnets   = [for k, v in local.azs : cidrsubnet(var.vpc_cidr, 8, k + 52)]

  enable_nat_gateway = true
  single_nat_gateway = var.single_nat_gateway

  # Nothing gets a public IP by accident
  map_public_ip_on_launch = false

  # Lock down the default security group (no rules = no traffic)
  manage_default_security_group  = true
  default_security_group_ingress = []
  default_security_group_egress  = []

  public_subnet_tags = {
    "kubernetes.io/role/elb" = 1
  }

  private_subnet_tags = {
    "kubernetes.io/role/internal-elb" = 1
    # Karpenter's EC2NodeClass discovers subnets by this tag
    "karpenter.sh/discovery" = local.name
  }
}


####################
# KMS Keys for logs
####################

data "aws_region" "current" {}

# Customer-managed key for log groups: we control (and audit) who can read logs
data "aws_iam_policy_document" "logs_kms" {
  # In a KMS *key policy*, resources = ["*"] means "this key only" - this is
  # the AWS-documented default policy shape, not a wildcard grant.
  #checkov:skip=CKV_AWS_109:Key policy; "*" refers to the key itself
  #checkov:skip=CKV_AWS_111:Key policy; "*" refers to the key itself
  #checkov:skip=CKV_AWS_356:Key policy; "*" refers to the key itself
  statement {
    sid       = "AccountAdministration"
    actions   = ["kms:*"]
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:${local.partition}:iam::${data.aws_caller_identity.current.account_id}:root"]
    }
  }

  statement {
    sid = "CloudWatchLogsUse"
    actions = [
      "kms:Encrypt*",
      "kms:Decrypt*",
      "kms:ReEncrypt*",
      "kms:GenerateDataKey*",
      "kms:Describe*",
    ]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["logs.${data.aws_region.current.region}.amazonaws.com"]
    }
    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:${local.partition}:logs:${data.aws_region.current.region}:${data.aws_caller_identity.current.account_id}:log-group:*"]
    }
  }
}

resource "aws_kms_key" "logs" {
  description             = "Encrypts CloudWatch log groups for ${local.name}"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  policy                  = data.aws_iam_policy_document.logs_kms.json
}

resource "aws_kms_alias" "logs" {
  name          = "alias/${local.name}-logs"
  target_key_id = aws_kms_key.logs.key_id
}


#################
# VPC Flow Logs
#################

# Flow logs record every connection in the VPC: source, destination, port, accepted or rejected. During an incident they answer "did that compromised pod talk to anything outside?". 
# The pieces fit together like this:
# 1.  A log group stores the records, encrypted with the KMS key, deleted after flow_log_retention_days (so storage cost stays bounded).
# 2.  An IAM role that only the VPC Flow Logs service can assume. The aws:SourceAccount condition prevents the "confused deputy" problem, where another account's flow logs trick AWS into writing through your role.
# 3.  A permission policy that only allows writing to this one log group (${arn}:* covers its log streams).
# 4.  The flow log itself: traffic_type = "ALL" captures accepted and rejected traffic, and max_aggregation_interval = 60 writes records every minute instead of every 10, for faster investigation.

resource "aws_cloudwatch_log_group" "flow_logs" {
  #checkov:skip=CKV_AWS_338:Retention is a variable (30d lab default); set 365+ for regulated environments
  name              = "/aws/vpc/${local.name}/flow-logs"
  retention_in_days = var.flow_log_retention_days
  kms_key_id        = aws_kms_key.logs.arn
}

data "aws_iam_policy_document" "flow_logs_trust" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["vpc-flow-logs.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [data.aws_caller_identity.current.account_id]
    }
  }
}

data "aws_iam_policy_document" "flow_logs" {
  statement {
    actions = [
      "logs:CreateLogStream",
      "logs:PutLogEvents",
      "logs:DescribeLogStreams",
    ]
    resources = ["${aws_cloudwatch_log_group.flow_logs.arn}:*"]
  }
}

resource "aws_iam_role" "flow_logs" {
  name               = "${local.name}-vpc-flow-logs"
  assume_role_policy = data.aws_iam_policy_document.flow_logs_trust.json
}

resource "aws_iam_role_policy" "flow_logs" {
  name   = "write-flow-logs"
  role   = aws_iam_role.flow_logs.id
  policy = data.aws_iam_policy_document.flow_logs.json
}

resource "aws_flow_log" "vpc" {
  vpc_id                   = module.vpc.vpc_id
  traffic_type             = "ALL"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.flow_logs.arn
  iam_role_arn             = aws_iam_role.flow_logs.arn
  max_aggregation_interval = 60
}


#################################
# VPC Endpoints (a cost decision)
#################################

# A VPC endpoint lets private subnets reach an AWS service without going through the NAT gateway, which charges for every GB it processes.

locals {
  interface_endpoint_services = ["ecr.api", "ecr.dkr", "sts", "sqs", "ec2", "ssm"]
}

module "vpc_endpoints" {
  source  = "terraform-aws-modules/vpc/aws//modules/vpc-endpoints"
  version = "6.7.3"

  vpc_id = module.vpc.vpc_id

  create_security_group      = var.enable_interface_endpoints
  security_group_name_prefix = "${local.name}-vpce-"
  security_group_description = "HTTPS to VPC interface endpoints from inside the VPC only"
  security_group_rules = {
    ingress_https = {
      description = "HTTPS from within the VPC"
      cidr_blocks = [module.vpc.vpc_cidr_block]
    }
  }

  endpoints = merge(
    {
      s3 = {
        service         = "s3"
        service_type    = "Gateway"
        route_table_ids = module.vpc.private_route_table_ids
        tags            = { Name = "${local.name}-s3" }
      }
    },
    {
      for svc in(var.enable_interface_endpoints ? local.interface_endpoint_services : []) :
      replace(svc, ".", "_") => {
        service             = svc
        private_dns_enabled = true
        subnet_ids          = module.vpc.private_subnets
        tags                = { Name = "${local.name}-${svc}" }
      }
    }
  )
}
