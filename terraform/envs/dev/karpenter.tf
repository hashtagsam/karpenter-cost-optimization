module "karpenter" {
  source  = "terraform-aws-modules/eks/aws//modules/karpenter"
  version = "21.29.0" # keep in lock-step with module.eks

  cluster_name = module.eks.cluster_name

  # Stable, readable name - referenced by the EC2NodeClass `spec.role`
  node_iam_role_use_name_prefix = false
  node_iam_role_name            = "${local.name}-karpenter-node"

  create_pod_identity_association = true

  # The controller policy is larger than the 6,144-character limit for a
  # standalone (managed) IAM policy. An inline role policy allows 10,240.
  enable_inline_policy = true

  node_iam_role_additional_policies = {
    AmazonSSMManagedInstanceCore = "arn:${local.partition}:iam::aws:policy/AmazonSSMManagedInstanceCore"
  }
}
