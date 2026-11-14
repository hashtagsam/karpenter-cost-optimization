variable "project" {
  description = "Project name, used as a prefix for every resource."
  type        = string
  default     = "karpenter-costopt"
}

variable "environment" {
  description = "Environment name (dev/stage/prod)."
  type        = string
  default     = "dev"
}

variable "region" {
  description = "AWS region."
  type        = string
  default     = "eu-west-2"
}

variable "cost_center" {
  description = "Cost-allocation tag value (activate the tag key in AWS Billing)."
  type        = string
  default     = "platform-engineering"
}

variable "owner" {
  description = "Owning team or person, used for tagging."
  type        = string
  default     = "platform-team"
}


#############
# Networking
#############

variable "vpc_cidr" {
  description = "CIDR for the VPC. /16 gives room for large private subnets (pods use VPC IPs)."
  type        = string
  default     = "10.20.0.0/16"
}

variable "single_nat_gateway" {
  description = "true = one NAT gateway (cheap, dev). false = one per AZ (HA, prod)."
  type        = bool
  default     = true
}

variable "enable_interface_endpoints" {
  description = <<-EOT
    Create interface VPC endpoints (ECR, STS, SQS, EC2, SSM). These bill per hour per AZ,
    so they only save money when NAT data-processing charges are high. The S3 gateway
    endpoint (free) is always created. See docs/adr/0003-vpc-endpoints.md.
  EOT
  type        = bool
  default     = false
}

variable "flow_log_retention_days" {
  description = "Retention for VPC flow logs in CloudWatch."
  type        = number
  default     = 30
}


######
# EKS
######

variable "kubernetes_version" {
  description = "EKS Kubernetes version. Check `aws eks describe-cluster-versions` for what your region supports."
  type        = string
  default     = "1.35"
}

variable "endpoint_public_access" {
  description = "Expose the EKS API publicly (restricted by endpoint_public_access_cidrs). Set false and use a VPN/bastion in prod."
  type        = bool
  default     = true
}

variable "endpoint_public_access_cidrs" {
  description = "CIDRs allowed to reach the public EKS API. Never use 0.0.0.0/0. e.g. [\"203.0.113.10/32\"]"
  type        = list(string)

  validation {
    condition     = length(var.endpoint_public_access_cidrs) > 0 && !contains(var.endpoint_public_access_cidrs, "0.0.0.0/0")
    error_message = "Provide at least one CIDR and do not allow 0.0.0.0/0."
  }
}

variable "admin_principal_arns" {
  description = "IAM role/user ARNs granted cluster-admin through EKS access entries (e.g. your SSO role)."
  type        = list(string)
  default     = []
}

variable "deletion_protection" {
  description = "Protect the EKS cluster from accidental deletion. Keep false in a throwaway lab."
  type        = bool
  default     = false
}

variable "control_plane_log_retention_days" {
  description = "Retention for EKS control-plane logs (audit, api, authenticator...)."
  type        = number
  default     = 90
}

variable "system_node_instance_types" {
  description = "Instance types for the small static node group that runs Karpenter itself (Graviton = cheaper)."
  type        = list(string)
  default     = ["m7g.large"]
}


###########################
# Account level guardrails
###########################
variable "enable_ebs_default_encryption" {
  description = "Turn on EBS encryption-by-default for this account+region (affects ALL new volumes in the region)."
  type        = bool
  default     = true
}

variable "create_spot_service_linked_role" {
  description = "Create the EC2 Spot service-linked role. Set false if it already exists in the account."
  type        = bool
  default     = true
}

variable "monthly_budget_usd" {
  description = "Monthly AWS budget for this lab. Alerts at 80% actual and 100% forecast."
  type        = number
  default     = 75
}

variable "budget_alert_emails" {
  description = "Emails for budget alerts. Leave empty to skip creating the budget."
  type        = list(string)
  default     = []
}
