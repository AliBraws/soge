# Lambdas: Python 3.14 on arm64, standard library + boto3 only (no third-party
# code to patch), OUTSIDE the VPC on purpose (they only call AWS APIs and the
# ECB feed: putting them in the VPC would require an internet path, i.e. a NAT,
# and EC2 ENI permissions on "*"). Reserved concurrency caps the blast radius.

data "archive_file" "functions" {
  type        = "zip"
  source_dir  = "${path.module}/../../app/functions"
  output_path = "${path.module}/.build/functions.zip"
  excludes    = ["tests", "__pycache__"]
}

locals {
  fn_env_common = {
    JWT_SECRET_ID    = aws_secretsmanager_secret.this["jwt"].arn
    ORIGIN_SECRET_ID = aws_secretsmanager_secret.this["origin"].arn
    TOKEN_TTL        = "300"
    SECRET_CACHE_TTL = "60"
  }
  fn_env_specific = {
    rotator_origin = { DISTRIBUTION_ID = aws_cloudfront_distribution.this.id }
    rates_sync     = { RATES_BUCKET = aws_s3_bucket.rates.bucket }
  }
  fn_concurrency = { authorizer = 20, issuer = 5, rotator_jwt = 1, rotator_origin = 1, rates_sync = 1 } # hard caps: a flood cannot scale Lambda cost
}

resource "aws_lambda_function" "fn" {
  for_each                       = local.functions
  function_name                  = "${local.n}-${replace(each.key, "_", "-")}"
  role                           = aws_iam_role.fn[each.key].arn
  runtime                        = "python3.14"
  architectures                  = ["arm64"]
  handler                        = "${each.value.file}.handler"
  filename                       = data.archive_file.functions.output_path
  source_code_hash               = data.archive_file.functions.output_base64sha256
  memory_size                    = 256
  timeout                        = each.key == "authorizer" ? 5 : 30
  reserved_concurrent_executions = local.fn_concurrency[each.key]
  kms_key_arn                    = aws_kms_key.this["app"].arn # environment variables encrypted with a CMK
  logging_config {
    log_format = "JSON"
    log_group  = aws_cloudwatch_log_group.this["fn-${each.key}"].name
  }
  environment {
    variables = merge(local.fn_env_common, each.value.env, lookup(local.fn_env_specific, each.key, {}))
  }
}

resource "aws_lambda_permission" "rotator" {
  for_each      = toset(["jwt", "origin"])
  statement_id  = "SecretsManagerRotation"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.fn["rotator_${each.key}"].function_name
  principal     = "secretsmanager.amazonaws.com"
  source_arn    = aws_secretsmanager_secret.this[each.key].arn
}

# rates_sync every hour (the ECB publishes once a day, ~16:00 CET), retries handled by the scheduler.
resource "aws_scheduler_schedule" "rates_sync" {
  name                         = "${local.n}-rates-sync"
  schedule_expression          = "rate(1 hour)"
  schedule_expression_timezone = "Europe/Paris"
  flexible_time_window { mode = "OFF" }
  target {
    arn      = aws_lambda_function.fn["rates_sync"].arn
    role_arn = aws_iam_role.scheduler.arn
    retry_policy {
      maximum_retry_attempts       = 3
      maximum_event_age_in_seconds = 600
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name                 = "${local.n}-scheduler"
  permissions_boundary = local.boundary_arn
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "scheduler.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } }
    }]
  })
}

resource "aws_iam_role_policy" "scheduler" {
  role = aws_iam_role.scheduler.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = "lambda:InvokeFunction", Resource = aws_lambda_function.fn["rates_sync"].arn }]
  })
}
