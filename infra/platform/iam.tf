# Least privilege: one execution role and one task role per ECS family, one
# role per Lambda; exact actions on exact ARNs; every role carries the
# bootstrap permissions boundary; no AWS-managed policy (they contain "*").

data "aws_iam_policy_document" "ecs_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ecs-tasks.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

locals {
  ecs_families = toset(["api", "migrate"])
}

# ---- execution roles: pull the image, write logs, inject secrets (ECS agent)
resource "aws_iam_role" "exec" {
  for_each             = local.ecs_families
  name                 = "${local.n}-${each.key}-exec"
  assume_role_policy   = data.aws_iam_policy_document.ecs_assume.json
  permissions_boundary = local.boundary_arn
}

data "aws_iam_policy_document" "exec" {
  for_each = local.ecs_families
  statement {
    # UNAVOIDABLE "*" (the only one at runtime): GetAuthorizationToken has no
    # resource type in IAM. It returns a registry token; pulls are scoped below.
    actions   = ["ecr:GetAuthorizationToken"]
    resources = ["*"]
  }
  statement {
    actions   = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"]
    resources = [local.ecr_repo_arn]
  }
  statement {
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.this[each.key].arn}:*"]
  }
  statement {
    actions   = ["secretsmanager:GetSecretValue"]
    resources = [each.key == "api" ? aws_secretsmanager_secret.this["quote"].arn : aws_rds_cluster.this.master_user_secret[0].secret_arn]
  }
  statement {
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.this["secrets"].arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["secretsmanager.${var.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "exec" {
  for_each = local.ecs_families
  role     = aws_iam_role.exec[each.key].id
  policy   = data.aws_iam_policy_document.exec[each.key].json
}

# ---- task roles: what the application code itself may do
resource "aws_iam_role" "task" {
  for_each             = local.ecs_families
  name                 = "${local.n}-${each.key}-task"
  assume_role_policy   = data.aws_iam_policy_document.ecs_assume.json
  permissions_boundary = local.boundary_arn
}

data "aws_iam_policy_document" "task_api" {
  statement {
    sid       = "IamDbAuthAppUserOnly"
    actions   = ["rds-db:connect"]
    resources = ["arn:${local.partition}:rds-db:${var.region}:${local.account_id}:dbuser:${aws_rds_cluster.this.cluster_resource_id}/soge_app"]
  }
  statement {
    sid       = "ReadRatesSnapshotOnly"
    actions   = ["s3:GetObject"]
    resources = ["${aws_s3_bucket.rates.arn}/rates/latest.json"]
  }
  statement {
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.this["rates"].arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["s3.${var.region}.amazonaws.com"]
    }
  }
}

resource "aws_iam_role_policy" "task_api" {
  role   = aws_iam_role.task["api"].id
  policy = data.aws_iam_policy_document.task_api.json
}
# The migrate task role intentionally has NO policy.

# ---- Lambdas (outside the VPC; the list lives in locals.tf)
resource "aws_iam_role" "fn" {
  for_each             = local.functions
  name                 = "${local.n}-fn-${replace(each.key, "_", "-")}"
  permissions_boundary = local.boundary_arn
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
    }]
  })
}

data "aws_iam_policy_document" "fn" {
  for_each = local.functions
  statement {
    sid       = "OwnLogGroup"
    actions   = ["logs:CreateLogStream", "logs:PutLogEvents"]
    resources = ["${aws_cloudwatch_log_group.this["fn-${each.key}"].arn}:*"]
  }
  statement {
    sid       = "DecryptOwnEnvironment"
    actions   = ["kms:Decrypt"]
    resources = [aws_kms_key.this["app"].arn]
    condition {
      test     = "StringEquals"
      variable = "kms:ViaService"
      values   = ["lambda.${var.region}.amazonaws.com"]
    }
  }
  dynamic "statement" {
    for_each = length(each.value.secrets) > 0 ? [1] : []
    content {
      sid       = "OwnSecrets"
      actions   = startswith(each.key, "rotator") ? ["secretsmanager:GetSecretValue", "secretsmanager:DescribeSecret", "secretsmanager:PutSecretValue", "secretsmanager:UpdateSecretVersionStage"] : ["secretsmanager:GetSecretValue"]
      resources = [for s in each.value.secrets : aws_secretsmanager_secret.this[s].arn]
    }
  }
  dynamic "statement" {
    for_each = length(each.value.secrets) > 0 ? [1] : []
    content {
      actions   = startswith(each.key, "rotator") ? ["kms:Decrypt", "kms:GenerateDataKey"] : ["kms:Decrypt"]
      resources = [aws_kms_key.this["secrets"].arn]
      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["secretsmanager.${var.region}.amazonaws.com"]
      }
    }
  }
  dynamic "statement" {
    for_each = each.key == "rotator_origin" ? [1] : []
    content {
      sid       = "UpdateOnlyThisDistribution"
      actions   = ["cloudfront:GetDistributionConfig", "cloudfront:UpdateDistribution"]
      resources = [aws_cloudfront_distribution.this.arn]
    }
  }
  dynamic "statement" {
    for_each = each.key == "rates_sync" ? [1] : []
    content {
      sid       = "WriteRatesSnapshotOnly"
      actions   = ["s3:PutObject"]
      resources = ["${aws_s3_bucket.rates.arn}/rates/latest.json"]
    }
  }
  dynamic "statement" {
    for_each = each.key == "rates_sync" ? [1] : []
    content {
      actions   = ["kms:GenerateDataKey"]
      resources = [aws_kms_key.this["rates"].arn]
      condition {
        test     = "StringEquals"
        variable = "kms:ViaService"
        values   = ["s3.${var.region}.amazonaws.com"]
      }
    }
  }
}

resource "aws_iam_role_policy" "fn" {
  for_each = local.functions
  role     = aws_iam_role.fn[each.key].id
  policy   = data.aws_iam_policy_document.fn[each.key].json
}
