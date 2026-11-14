terraform {
  # >= 1.10 for S3 native state locking (use_lockfile)
  required_version = ">= 1.10.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.59, < 7.0" # EKS module v21.x needs >= 6.59
    }
  }
}

provider "aws" {
  region = var.region

  # Every taggable resource gets cost-allocation tags. Activate these keys
  # under Billing > Cost allocation tags so they show up in Cost Explorer.
  default_tags {
    tags = local.cost_tags
  }
}
