

################################################################################
# Account-level guardrails
################################################################################

# Every new EBS volume in this account+region is encrypted (AWS-managed key).
# Covers Karpenter nodes, node-group nodes and PVCs, even if someone forgets
# `encrypted: true`.
resource "aws_ebs_encryption_by_default" "this" {
  count   = var.enable_ebs_default_encryption ? 1 : 0
  enabled = true
}

# Spot instances need this service-linked role; it is account-wide and may
# already exist (set create_spot_service_linked_role = false in that case).
resource "aws_iam_service_linked_role" "spot" {
  count            = var.create_spot_service_linked_role ? 1 : 0
  aws_service_name = "spot.amazonaws.com"
}

# Cost guardrail for the lab itself: alert before the bill surprises you.
resource "aws_budgets_budget" "lab" {
  count = length(var.budget_alert_emails) > 0 ? 1 : 0

  name         = "${local.name}-monthly"
  budget_type  = "COST"
  limit_amount = tostring(var.monthly_budget_usd)
  limit_unit   = "USD"
  time_unit    = "MONTHLY"

  cost_filter {
    name = "TagKeyValue"
    # Format is "user:<TagKey>$<TagValue>"; the tag key must be activated as a
    # cost-allocation tag in Billing, otherwise this filter matches nothing.
    values = [format("user:Project$%s", var.project)]
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 80
    threshold_type             = "PERCENTAGE"
    notification_type          = "ACTUAL"
    subscriber_email_addresses = var.budget_alert_emails
  }

  notification {
    comparison_operator        = "GREATER_THAN"
    threshold                  = 100
    threshold_type             = "PERCENTAGE"
    notification_type          = "FORECASTED"
    subscriber_email_addresses = var.budget_alert_emails
  }
}
