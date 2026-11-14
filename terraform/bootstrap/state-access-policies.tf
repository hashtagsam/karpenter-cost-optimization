# Read-only state access for the plan role. PR code runs with this role
# (Terraform providers can execute arbitrary code), so it must not be able
# to overwrite or delete state. Plans run with -lock=false.
# Two levels of access, following least privilege. The plan role can only read state. 
# That matters because a pull request can contain Terraform code that runs arbitrary 
# programs during plan, so a malicious PR must not be able to overwrite your state. 
# The apply role needs write access, because applying updates state and creates and 
# deletes the .tflock lock file.

############################
# State access
############################

data "aws_iam_policy_document" "state_read" {
  statement {
    sid       = "StateBucketList"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }

  statement {
    sid       = "StateObjectsRead"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]
  }

  statement {
    sid       = "StateKmsDecrypt"
    actions   = ["kms:Decrypt", "kms:DescribeKey"]
    resources = [aws_kms_key.state.arn]
  }
}

# Read/write state access (incl. .tflock lock files) for the apply role.
# Explicit, so it keeps working when AdministratorAccess is scoped down.
data "aws_iam_policy_document" "state_access" {
  statement {
    sid       = "StateBucketList"
    actions   = ["s3:ListBucket"]
    resources = [aws_s3_bucket.state.arn]
  }

  statement {
    sid       = "StateObjects"
    actions   = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"]
    resources = ["${aws_s3_bucket.state.arn}/*"]
  }

  statement {
    sid       = "StateKms"
    actions   = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = [aws_kms_key.state.arn]
  }
}


###################
# Plan Role
###################
data "aws_iam_policy_document" "plan_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values = [
        "repo:${local.repo}:pull_request",
        "repo:${local.repo}:ref:refs/heads/main",
      ]
    }
  }
}

data "aws_iam_policy_document" "plan_guardrails" {
  statement {
    sid    = "DenyDataExfiltration"
    effect = "Deny"
    actions = [
      "secretsmanager:GetSecretValue",
      "dynamodb:GetItem",
      "dynamodb:BatchGetItem",
      "dynamodb:Query",
      "dynamodb:Scan",
      "sqs:ReceiveMessage",
      "lambda:GetFunction", # returns a pre-signed URL to the code package
    ]
    resources = ["*"]
  }

  # Plan must read AWS *public* parameters (the EKS module looks up the latest
  # Bottlerocket AMI release in /aws/service/...), but not our own parameters.
  statement {
    sid    = "DenyPrivateParameterReads"
    effect = "Deny"
    actions = [
      "ssm:GetParameter",
      "ssm:GetParameters",
      "ssm:GetParametersByPath",
    ]
    not_resources = ["arn:${local.partition}:ssm:*::parameter/aws/service/*"]
  }

  statement {
    sid           = "DenyObjectReadsOutsideState"
    effect        = "Deny"
    actions       = ["s3:GetObject", "s3:GetObjectVersion"]
    not_resources = ["${aws_s3_bucket.state.arn}/*"]
  }

  statement {
    sid           = "DenyDecryptOutsideStateKey"
    effect        = "Deny"
    actions       = ["kms:Decrypt"]
    not_resources = [aws_kms_key.state.arn]
  }
}

resource "aws_iam_role" "plan" {
  name                 = "${var.project}-gha-plan"
  description          = "GitHub Actions: terraform plan (read-only) for ${local.repo}"
  assume_role_policy   = data.aws_iam_policy_document.plan_trust.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "plan_readonly" {
  role       = aws_iam_role.plan.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/ReadOnlyAccess"
}

resource "aws_iam_role_policy" "plan_state" {
  name   = "terraform-state-read"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.state_read.json
}

resource "aws_iam_role_policy" "plan_guardrails" {
  name   = "guardrails"
  role   = aws_iam_role.plan.id
  policy = data.aws_iam_policy_document.plan_guardrails.json
}



#################
# Apply Role
#################
# The apply role can change real infrastructure, so it gets three layers of protection:
# 1.  Who can use it: the sub must be repo:you/repo:environment:dev. GitHub only issues that subject to a job running in the dev Environment, and you configure that environment to require a human reviewer. So every apply needs a person to click Approve.
# 2.  What it can do: AdministratorAccess, because this stack creates IAM roles and that needs broad IAM rights. This is a known, documented trade-off (ADR-0004).
# 3.  What it can never do: explicit denies. It can't create IAM users or access keys (no backdoor credentials), touch AWS Organizations, switch off CloudTrail, GuardDuty or Config (no covering tracks), weaken the state bucket, or edit its own role or the plan role (no privilege escalation).

data "aws_iam_policy_document" "apply_trust" {
  statement {
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = [aws_iam_openid_connect_provider.github.arn]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:${local.repo}:environment:${var.github_environment}"]
    }
  }
}

data "aws_iam_policy_document" "apply_guardrails" {
  statement {
    sid    = "DenyLongLivedCredentials"
    effect = "Deny"
    actions = [
      "iam:CreateUser",
      "iam:CreateAccessKey",
      "iam:CreateLoginProfile",
      "iam:UpdateLoginProfile",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "DenyAccountAndAuditTampering"
    effect = "Deny"
    actions = [
      "organizations:*",
      "account:*",
      "cloudtrail:StopLogging",
      "cloudtrail:DeleteTrail",
      "guardduty:DeleteDetector",
      "config:DeleteConfigurationRecorder",
      "config:StopConfigurationRecorder",
    ]
    resources = ["*"]
  }

  statement {
    sid    = "ProtectStateBucket"
    effect = "Deny"
    actions = [
      "s3:DeleteBucket",
      "s3:PutBucketPolicy",
      "s3:DeleteBucketPolicy",
      "s3:PutBucketVersioning",
      "s3:PutEncryptionConfiguration",
    ]
    resources = [aws_s3_bucket.state.arn]
  }

  statement {
    sid       = "ProtectOwnRoles"
    effect    = "Deny"
    actions   = ["iam:*"]
    resources = [aws_iam_role.plan.arn, "arn:${local.partition}:iam::${local.account_id}:role/${var.project}-gha-apply"]
  }
}

resource "aws_iam_role" "apply" {
  name                 = "${var.project}-gha-apply"
  description          = "GitHub Actions: terraform apply for ${local.repo} (env: ${var.github_environment})"
  assume_role_policy   = data.aws_iam_policy_document.apply_trust.json
  max_session_duration = 3600
}

resource "aws_iam_role_policy_attachment" "apply_admin" {
  #checkov:skip=CKV_AWS_274:Apply role must manage IAM/EKS/VPC; scoped by OIDC trust + explicit deny guardrails (see ADR-0004)
  role       = aws_iam_role.apply.name
  policy_arn = "arn:${local.partition}:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_role_policy" "apply_state" {
  name   = "terraform-state"
  role   = aws_iam_role.apply.id
  policy = data.aws_iam_policy_document.state_access.json
}

resource "aws_iam_role_policy" "apply_guardrails" {
  name   = "guardrails"
  role   = aws_iam_role.apply.id
  policy = data.aws_iam_policy_document.apply_guardrails.json
}
