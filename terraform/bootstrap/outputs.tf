output "state_bucket" {
  description = "Put this in terraform/envs/dev/backend.hcl"
  value       = aws_s3_bucket.state.bucket
}

output "state_kms_key_arn" {
  description = "KMS key encrypting the state bucket."
  value       = aws_kms_key.state.arn
}

output "plan_role_arn" {
  description = "Set as GitHub repository variable AWS_PLAN_ROLE_ARN"
  value       = aws_iam_role.plan.arn
}

output "apply_role_arn" {
  description = "Set as GitHub environment variable AWS_APPLY_ROLE_ARN (environment: dev)"
  value       = aws_iam_role.apply.arn
}
