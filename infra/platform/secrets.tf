# Secrets: nothing sensitive ever lands in the Terraform state or plan.
#
# * ephemeral "random_password" generates a value that exists only during the
#   run (Terraform >= 1.10), passed to a write-only argument (secret_string_wo,
#   Terraform >= 1.11) that is sent to AWS and never persisted. Only the integer
#   *_wo_version is stored.
# * The JWT signing key and the origin-verify header are then ROTATED by
#   Lambda (rotate_immediately): the bootstrap value is replaced within minutes.
# * Aurora's admin password is generated, stored and rotated by RDS itself
#   (manage_master_user_password): Terraform never sees it.
# * The application has no DB password at all (IAM database authentication).

ephemeral "random_password" "bootstrap" {
  for_each = toset(["jwt", "origin", "quote"])
  length   = 64
  special  = false
}

resource "aws_secretsmanager_secret" "this" {
  for_each                = toset(["jwt", "origin", "quote"])
  name_prefix             = "${local.n}/${each.key}-"
  kms_key_id              = aws_kms_key.this["secrets"].arn
  recovery_window_in_days = 7
}

resource "aws_secretsmanager_secret_version" "bootstrap" {
  for_each                 = aws_secretsmanager_secret.this
  secret_id                = each.value.id
  secret_string_wo         = ephemeral.random_password.bootstrap[each.key].result
  secret_string_wo_version = 1
  lifecycle { ignore_changes = [version_stages] } # rotation owns the stages afterwards
}

# Resource policies: only the intended consumers can read each secret, even if an
# identity policy elsewhere in the account were too broad.
locals {
  # The Terraform apply role is listed because the provider refreshes the version
  # resource; the value itself is write-only and never stored.
  tf_apply_role = "arn:${local.partition}:iam::${local.account_id}:role/${local.n}-gha-apply"
  secret_readers = {
    jwt    = [aws_iam_role.fn["authorizer"].arn, aws_iam_role.fn["issuer"].arn, aws_iam_role.fn["rotator_jwt"].arn]
    origin = [aws_iam_role.fn["authorizer"].arn, aws_iam_role.fn["rotator_origin"].arn]
    quote  = [aws_iam_role.exec["api"].arn]
  }
}

resource "aws_secretsmanager_secret_policy" "this" {
  for_each   = aws_secretsmanager_secret.this
  secret_arn = each.value.arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid       = "OnlyIntendedReaders"
      Effect    = "Deny"
      Principal = "*" # Deny-everyone-except pattern: a Deny, not a grant
      Action    = "secretsmanager:GetSecretValue"
      Resource  = each.value.arn
      Condition = {
        StringNotEquals = { "aws:PrincipalArn" = concat(local.secret_readers[each.key], [local.tf_apply_role]) }
        Bool            = { "aws:PrincipalIsAWSService" = "false" }
      }
    }]
  })
}

# Rotation: JWT key every 4 hours (tokens live 5 min; authorizer accepts the
# previous key, so rotation is invisible to clients). Origin-verify every 7 days.
resource "aws_secretsmanager_secret_rotation" "jwt" {
  secret_id           = aws_secretsmanager_secret.this["jwt"].id
  rotation_lambda_arn = aws_lambda_function.fn["rotator_jwt"].arn
  rotate_immediately  = true
  rotation_rules { schedule_expression = "rate(4 hours)" }
  depends_on = [aws_secretsmanager_secret_version.bootstrap, aws_lambda_permission.rotator]
}

resource "aws_secretsmanager_secret_rotation" "origin" {
  secret_id           = aws_secretsmanager_secret.this["origin"].id
  rotation_lambda_arn = aws_lambda_function.fn["rotator_origin"].arn
  rotate_immediately  = true
  rotation_rules { automatically_after_days = 7 }
  depends_on = [aws_secretsmanager_secret_version.bootstrap, aws_lambda_permission.rotator, aws_cloudfront_distribution.this]
}
