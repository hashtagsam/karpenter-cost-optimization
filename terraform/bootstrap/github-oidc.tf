# this is the OIDC - AWS connector 
# GitHub is the OIDC provider which signs a short-lived token/JWT and sends the signed keys to AWS STS with AssumeRoleWithWebIdentity
# AWS STS validates the token against the publicly available GitHub keys and provides AWS credentials for up to one hour. 
# No stored keys, therefore nothing to steal, leak

resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}
