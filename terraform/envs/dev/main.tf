data "aws_availability_zones" "available" {
  # Exclude Local Zones / Wavelength - Karpenter would otherwise try to launch there
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_partition" "current" {}
data "aws_caller_identity" "current" {}

locals {
  name      = "${var.project}-${var.environment}"
  partition = data.aws_partition.current.partition
  azs       = slice(data.aws_availability_zones.available.names, 0, 3)

  cost_tags = {
    Project     = var.project
    Environment = var.environment
    CostCenter  = var.cost_center
    Owner       = var.owner
    ManagedBy   = "terraform"
  }
}
