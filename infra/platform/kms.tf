# Customer-managed keys (CMK), one per data domain: separate key policies,
# separate blast radius, every use visible in CloudTrail.
# Key material: AWS KMS-generated (FIPS 140-3 L3 HSMs), automatic rotation every
# 90 days (key ARN unchanged, old material kept to decrypt older data).
# BYOK (imported material) deliberately NOT used: see docs/DECISIONS.md ADR-013.
#
# Key policies list explicit actions (no "kms:*"). Note: in a KEY policy,
# Resource "*" is mandatory and means "this key", it is not a wildcard grant.

locals {
  kms_domains = {
    data    = "Aurora storage, Performance Insights"
    secrets = "Secrets Manager (JWT key, origin-verify, quote key, DB admin)"
    logs    = "CloudWatch Logs"
    rates   = "rates snapshot bucket"
    app     = "Lambda environment, SNS alarms topic"
  }

  kms_admin_actions = [
    "kms:DescribeKey", "kms:GetKeyPolicy", "kms:PutKeyPolicy", "kms:GetKeyRotationStatus",
    "kms:EnableKeyRotation", "kms:RotateKeyOnDemand", "kms:ListKeyRotations", "kms:ListResourceTags",
    "kms:TagResource", "kms:UntagResource", "kms:CreateAlias", "kms:DeleteAlias", "kms:UpdateAlias",
    "kms:UpdateKeyDescription", "kms:EnableKey", "kms:DisableKey", "kms:ScheduleKeyDeletion",
    "kms:CancelKeyDeletion", "kms:ListGrants", "kms:CreateGrant", "kms:RevokeGrant", "kms:RetireGrant",
  ]
  # IAM delegation: identity policies in this account may grant these crypto
  # operations; each role policy then scopes them (kms:ViaService).
  kms_crypto_actions = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncryptFrom", "kms:ReEncryptTo", "kms:GenerateDataKey", "kms:GenerateDataKeyWithoutPlaintext"]
}

data "aws_iam_policy_document" "kms" {
  for_each = local.kms_domains
  statement {
    sid       = "AccountAdministration"
    actions   = local.kms_admin_actions
    resources = ["*"] # = this key
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_id}:root"]
    }
  }
  statement {
    sid       = "IamDelegatedCrypto"
    actions   = local.kms_crypto_actions
    resources = ["*"] # = this key
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_id}:root"]
    }
  }
  dynamic "statement" {
    for_each = each.key == "logs" ? [1] : []
    content {
      sid       = "CloudWatchLogsOwnGroupsOnly"
      actions   = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncryptFrom", "kms:ReEncryptTo", "kms:GenerateDataKey", "kms:DescribeKey"]
      resources = ["*"]
      principals {
        type        = "Service"
        identifiers = ["logs.${var.region}.amazonaws.com"]
      }
      condition {
        test     = "ArnLike"
        variable = "kms:EncryptionContext:aws:logs:arn"
        values   = ["arn:aws:logs:${var.region}:${local.account_id}:log-group:/soge/*", "arn:aws:logs:${var.region}:${local.account_id}:log-group:aws-waf-logs-soge-*"]
      }
    }
  }
  dynamic "statement" {
    for_each = each.key == "app" ? [1] : []
    content {
      sid       = "CloudWatchAlarmsPublishToEncryptedTopic"
      actions   = ["kms:Decrypt", "kms:GenerateDataKey"]
      resources = ["*"]
      principals {
        type        = "Service"
        identifiers = ["cloudwatch.amazonaws.com"]
      }
      condition {
        test     = "StringEquals"
        variable = "aws:SourceAccount"
        values   = [local.account_id]
      }
    }
  }
}

resource "aws_kms_key" "this" {
  for_each                = local.kms_domains
  description             = "${local.n} ${each.key}: ${each.value}"
  enable_key_rotation     = true
  rotation_period_in_days = 90
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.kms[each.key].json
}

resource "aws_kms_alias" "this" {
  for_each      = local.kms_domains
  name          = "alias/${local.n}-${each.key}"
  target_key_id = aws_kms_key.this[each.key].key_id
}

# us-east-1: CloudFront WAF logs must live there.
data "aws_iam_policy_document" "kms_edge_logs" {
  statement {
    sid       = "AccountAdministration"
    actions   = local.kms_admin_actions
    resources = ["*"]
    principals {
      type        = "AWS"
      identifiers = ["arn:aws:iam::${local.account_id}:root"]
    }
  }
  statement {
    sid       = "CloudWatchLogsEdgeWafOnly"
    actions   = ["kms:Encrypt", "kms:Decrypt", "kms:ReEncryptFrom", "kms:ReEncryptTo", "kms:GenerateDataKey", "kms:DescribeKey"]
    resources = ["*"]
    principals {
      type        = "Service"
      identifiers = ["logs.us-east-1.amazonaws.com"]
    }
    condition {
      test     = "ArnLike"
      variable = "kms:EncryptionContext:aws:logs:arn"
      values   = ["arn:aws:logs:us-east-1:${local.account_id}:log-group:aws-waf-logs-soge-*"]
    }
  }
}

resource "aws_kms_key" "edge_logs" {
  provider                = aws.use1
  description             = "${local.n} edge WAF logs (us-east-1)"
  enable_key_rotation     = true
  rotation_period_in_days = 90
  deletion_window_in_days = 30
  policy                  = data.aws_iam_policy_document.kms_edge_logs.json
}
