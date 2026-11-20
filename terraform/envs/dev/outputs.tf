output "region" {
  value = var.region
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}

output "cluster_version" {
  value = module.eks.cluster_version
}

output "karpenter_interruption_queue" {
  description = "Passed to the Karpenter Helm chart as settings.interruptionQueue"
  value       = module.karpenter.queue_name
}

output "karpenter_node_role_name" {
  description = "Used as spec.role in the EC2NodeClass"
  value       = module.karpenter.node_iam_role_name
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "configure_kubectl" {
  description = "Run this to point kubectl at the cluster"
  value       = "aws eks update-kubeconfig --region ${var.region} --name ${module.eks.cluster_name}"
}
