# bootstrap — run ONCE, from a laptop, with an admin SSO session.
# Creates what CI needs before it can run: Terraform state (S3 + KMS), GitHub
# OIDC trust + 3 CI roles, the ECR repository. After this, no long-lived AWS key
# exists anywhere.

data "aws_caller_identity" "this" {}
data "aws_partition" "this" {}

locals {
  account_id = data.aws_caller_identity.this.account_id
  kms_admin_actions = [
    "kms:DescribeKey", "kms:GetKeyPolicy", "kms:PutKeyPolicy", "kms:GetKeyRotationStatus",
    "kms:EnableKeyRotation", "kms:ListKeyRotations", "kms:ListResourceTags", "kms:TagResource",
    "kms:UntagResource", "kms:CreateAlias", "kms:DeleteAlias", "kms:UpdateAlias", "kms:ScheduleKeyDeletion",
    "kms:CancelKeyDeletion", "kms:ListGrants", "kms:CreateGrant", "kms:RevokeGrant", "kms:RetireGrant",
    "kms:Encrypt", "kms:Decrypt", "kms:ReEncryptFrom", "kms:ReEncryptTo", "kms:GenerateDataKey", "kms:GenerateDataKeyWithoutPlaintext",
  ]
}

# ---------------------------------------------------------------- KMS
data "aws_iam_policy_document" "kms" {
  statement {
    sid       = "AccountAdministrationAndIamDelegation"
    actions   = local.kms_admin_actions
    resources = ["*"] # in a key policy "*" means "this key"
    principals {
      type        = "AWS"
      identifiers = ["arn:${data.aws_partition.this.partition}:iam::${local.account_id}:root"]
    }
  }
}

resource "aws_kms_key" "this" {
  for_each                = toset(["state", "ecr"])
  description             = "${local.name} ${each.key}"
  enable_key_rotation     = true
  rotation_period_in_days = 90
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.kms.json
}

resource "aws_kms_alias" "this" {
  for_each      = aws_kms_key.this
  name          = "alias/${local.name}-${each.key}"
  target_key_id = each.value.key_id
}

# ---------------------------------------------------------------- state bucket
# Deterministic name: GitHub can be configured before the bootstrap runs.
resource "aws_s3_bucket" "state" {
  bucket        = "${local.name}-tfstate-${local.account_id}"
  force_destroy = var.allow_destroy
}

resource "aws_s3_bucket_versioning" "state" {
  bucket = aws_s3_bucket.state.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm     = "aws:kms"
      kms_master_key_id = aws_kms_key.this["state"].arn
    }
    bucket_key_enabled = true
  }
}

resource "aws_s3_bucket_public_access_block" "state" {
  bucket                  = aws_s3_bucket.state.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "state" {
  bucket = aws_s3_bucket.state.id
  rule { object_ownership = "BucketOwnerEnforced" }
}

resource "aws_s3_bucket_lifecycle_configuration" "state" {
  bucket = aws_s3_bucket.state.id
  rule {
    id     = "old-state-versions"
    status = "Enabled"
    filter {}
    noncurrent_version_expiration { noncurrent_days = 90 }
  }
}

resource "aws_s3_bucket_policy" "state" {
  bucket = aws_s3_bucket.state.id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "TLSOnly" # Deny statement: Principal "*" grants nothing
      Effect    = "Deny"
      Principal = "*"
      Action    = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject", "s3:ListBucket"]
      Resource  = [aws_s3_bucket.state.arn, "${aws_s3_bucket.state.arn}/*"]
      Condition = { Bool = { "aws:SecureTransport" = "false" } }
    }]
  })
}

# ---------------------------------------------------------------- ECR
resource "aws_ecr_repository" "api" {
  name                 = "${local.name}/api"
  force_delete         = var.allow_destroy
  image_tag_mutability = "IMMUTABLE" # images are deployed by digest, tags can never be moved
  image_scanning_configuration { scan_on_push = true }
  encryption_configuration {
    encryption_type = "KMS"
    kms_key         = aws_kms_key.this["ecr"].arn
  }
}

resource "aws_ecr_lifecycle_policy" "api" {
  repository = aws_ecr_repository.api.name
  policy = jsonencode({
    rules = [{
      rulePriority = 1
      description  = "keep the last 30 images (rollback window)"
      selection    = { tagStatus = "any", countType = "imageCountMoreThan", countNumber = 30 }
      action       = { type = "expire" }
    }]
  })
}

# ---------------------------------------------------------------- GitHub OIDC
resource "aws_iam_openid_connect_provider" "github" {
  url            = "https://token.actions.githubusercontent.com"
  client_id_list = ["sts.amazonaws.com"]
}

locals {
  # plan  : any PR or branch of this repo, read-only
  # push  : main only, ECR push only
  # apply : the protected "prod" environment only (required reviewers in GitHub)
  # Repositories created after 2026-07-15 get an immutable subject:
  # repo:<owner>@<owner_id>/<repo>@<repo_id>:... (renaming or recreating a repo
  # can no longer inherit its trust). The prefix is read from GitHub, never guessed:
  #   gh api repos/<owner>/<repo>/actions/oidc/customization/sub --jq .sub_claim_prefix
  ci_subjects = {
    plan  = ["${var.github_sub_prefix}:pull_request", "${var.github_sub_prefix}:ref:refs/heads/*"]
    push  = ["${var.github_sub_prefix}:ref:refs/heads/main"]
    apply = ["${var.github_sub_prefix}:environment:prod"]
  }
  boundary_arn = "arn:${data.aws_partition.this.partition}:iam::${local.account_id}:policy/${local.name}-boundary"
}

resource "aws_iam_role" "ci" {
  for_each             = local.ci_subjects
  name                 = "${local.name}-gha-${each.key}"
  max_session_duration = 3600
  permissions_boundary = aws_iam_policy.boundary.arn
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Federated = aws_iam_openid_connect_provider.github.arn }
      Action    = "sts:AssumeRoleWithWebIdentity"
      Condition = {
        StringEquals = { "token.actions.githubusercontent.com:aud" = "sts.amazonaws.com" }
        StringLike   = { "token.actions.githubusercontent.com:sub" = each.value }
      }
    }]
  })
}

# Permissions boundary carried by the CI roles AND by every role the platform
# creates: no privilege escalation, no IAM users/keys, no account-level changes.
resource "aws_iam_policy" "boundary" {
  name = "${local.name}-boundary"
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "AllowWithinBoundary", Effect = "Allow", Action = "*", Resource = "*" },
      {
        Sid      = "ProtectTheGuardrails"
        Effect   = "Deny"
        Action   = ["iam:DeleteRolePermissionsBoundary", "iam:CreatePolicyVersion", "iam:SetDefaultPolicyVersion", "iam:DeletePolicy", "iam:UpdateAssumeRolePolicy", "iam:CreateOpenIDConnectProvider", "iam:DeleteOpenIDConnectProvider", "iam:UpdateOpenIDConnectProviderThumbprint"]
        Resource = [local.boundary_arn, "arn:${data.aws_partition.this.partition}:iam::${local.account_id}:role/${local.name}-gha-*", aws_iam_openid_connect_provider.github.arn]
      },
      {
        Sid       = "NewRolesMustCarryTheBoundary"
        Effect    = "Deny"
        Action    = ["iam:CreateRole", "iam:PutRolePermissionsBoundary"]
        Resource  = "*"
        Condition = { StringNotEquals = { "iam:PermissionsBoundary" = local.boundary_arn } }
      },
      { Sid = "NoUsersNoKeys", Effect = "Deny", Action = ["iam:CreateUser", "iam:CreateAccessKey", "iam:CreateLoginProfile"], Resource = "*" },
      { Sid = "NoAccountLevelChanges", Effect = "Deny", Action = ["organizations:LeaveOrganization", "account:CloseAccount", "account:PutAlternateContact", "account:EnableRegion", "account:DisableRegion"], Resource = "*" },
    ]
  })
}

resource "aws_iam_role_policy_attachment" "plan" {
  role       = aws_iam_role.ci["plan"].name
  policy_arn = "arn:${data.aws_partition.this.partition}:iam::aws:policy/ReadOnlyAccess"
}

# The ONE documented exception to "no wildcard": the deployment identity has to
# create ~20 kinds of resources. Constrained by the OIDC subject (protected
# environment with reviewers) and by the boundary above. Production step:
# replace it with a policy generated by IAM Access Analyzer from CloudTrail.
resource "aws_iam_role_policy_attachment" "apply" {
  role       = aws_iam_role.ci["apply"].name
  policy_arn = "arn:${data.aws_partition.this.partition}:iam::aws:policy/AdministratorAccess"
}

resource "aws_iam_role_policy" "push" {
  role = aws_iam_role.ci["push"].id
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Sid = "RegistryToken", Effect = "Allow", Action = "ecr:GetAuthorizationToken", Resource = "*" }, # no resource type exists for this action
      {
        Sid      = "PushThisRepositoryOnly"
        Effect   = "Allow"
        Action   = ["ecr:BatchCheckLayerAvailability", "ecr:InitiateLayerUpload", "ecr:UploadLayerPart", "ecr:CompleteLayerUpload", "ecr:PutImage", "ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer", "ecr:DescribeImages"]
        Resource = aws_ecr_repository.api.arn
      },
      { Sid = "EncryptLayers", Effect = "Allow", Action = ["kms:GenerateDataKey", "kms:Decrypt"], Resource = aws_kms_key.this["ecr"].arn },
    ]
  })
}

resource "aws_iam_role_policy" "state" {
  for_each = { plan = aws_iam_role.ci["plan"].id, apply = aws_iam_role.ci["apply"].id }
  role     = each.value
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      { Effect = "Allow", Action = "s3:ListBucket", Resource = aws_s3_bucket.state.arn },
      { Effect = "Allow", Action = ["s3:GetObject", "s3:PutObject", "s3:DeleteObject"], Resource = "${aws_s3_bucket.state.arn}/platform/*" }, # Put/Delete for the .tflock file
      { Effect = "Allow", Action = ["kms:Decrypt", "kms:Encrypt", "kms:GenerateDataKey"], Resource = aws_kms_key.this["state"].arn },
    ]
  })
}
