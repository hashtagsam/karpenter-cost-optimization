variable "project" {
  description = "Short project name used as a prefix for resource names."
  type        = string
  default     = "karpenter-costopt"

  validation {
    condition     = can(regex("^[a-z0-9-]{3,24}$", var.project))
    error_message = "project must be 3-24 chars of lowercase letters, digits and hyphens."
  }
}

variable "region" {
  description = "AWS region for the state bucket."
  type        = string
  default     = "eu-west-2"
}

variable "github_org" {
  description = "GitHub user or organisation that owns the repository."
  type        = string
}

variable "github_repo" {
  description = "GitHub repository name (without the owner)."
  type        = string
  default     = "karpenter-cost-optimization"
}

variable "github_environment" {
  description = "GitHub Environment (with required reviewers) allowed to assume the apply role."
  type        = string
  default     = "dev"
}
