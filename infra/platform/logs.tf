# Every log group is created by Terraform (never auto-created by a service),
# KMS-encrypted, with a retention period.
locals {
  log_groups = merge(
    { api = 30, migrate = 30, apigw = 90, flow = 90 },
    { for f in keys(local.functions) : "fn-${f}" => 30 },
  )
}

resource "aws_cloudwatch_log_group" "this" {
  for_each          = local.log_groups
  name              = "/soge/${var.environment}/${each.key}"
  retention_in_days = each.value
  kms_key_id        = aws_kms_key.this["logs"].arn
}

