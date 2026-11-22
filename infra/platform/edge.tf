# Public entry point (.com): CloudFront
#   * TLS 1.3 only towards viewers (TLSv1.3_2025), HTTP/2 + HTTP/3, IPv6
#   * TLS 1.3 towards the origin (negotiated automatically; the API Gateway
#     custom domain accepts nothing else)
#   * AWS WAF (managed rule groups), AWS Shield Standard
#   * security headers added, fingerprinting headers removed
#   * origin-verify header (rotating secret) so the regional API cannot be
#     called while bypassing the edge

data "aws_cloudfront_cache_policy" "disabled" { name = "Managed-CachingDisabled" }
data "aws_cloudfront_cache_policy" "optimized" { name = "Managed-CachingOptimized" }
data "aws_cloudfront_origin_request_policy" "all_but_host" { name = "Managed-AllViewerExceptHostHeader" }

resource "aws_cloudfront_response_headers_policy" "this" {
  name = "${local.n}-headers"
  security_headers_config {
    strict_transport_security {
      access_control_max_age_sec = 63072000
      include_subdomains         = true
      preload                    = true
      override                   = true
    }
    content_type_options { override = true }
    frame_options {
      frame_option = "DENY"
      override     = true
    }
    referrer_policy {
      referrer_policy = "no-referrer"
      override        = true
    }
    content_security_policy {
      content_security_policy = "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'none'"
      override                = true
    }
  }
  custom_headers_config {
    items {
      header   = "Permissions-Policy"
      value    = "camera=(), microphone=(), geolocation=()"
      override = true
    }
  }
  remove_headers_config {
    dynamic "items" {
      for_each = ["server", "x-amz-apigw-id", "x-amzn-requestid", "x-amzn-remapped-server", "x-amzn-remapped-date", "x-amzn-remapped-content-length", "x-amzn-trace-id"]
      content { header = items.value }
    }
  }
}

resource "aws_cloudfront_distribution" "this" {
  enabled         = true
  is_ipv6_enabled = true
  http_version    = "http2and3"
  price_class     = "PriceClass_100"
  comment         = "soge"
  aliases         = [local.app_fqdn]
  web_acl_id      = aws_wafv2_web_acl.edge.arn

  origin {
    origin_id   = "apigw"
    domain_name = local.origin_fqdn
    custom_origin_config {
      http_port                = 80
      https_port               = 443
      origin_protocol_policy   = "https-only"
      origin_ssl_protocols     = ["TLSv1.2"] # floor; TLS 1.3 is negotiated (the origin accepts only 1.3)
      origin_read_timeout      = 15
      origin_keepalive_timeout = 30
    }
    custom_header {
      name  = "X-Origin-Verify"
      value = "bootstrap-replaced-by-rotation" # real value pushed by the rotation Lambda
    }
    connection_attempts = 3
    connection_timeout  = 5
  }

  default_cache_behavior {
    target_origin_id           = "apigw"
    viewer_protocol_policy     = "redirect-to-https"
    allowed_methods            = ["GET", "HEAD", "OPTIONS"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.optimized.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.this.id
  }

  ordered_cache_behavior {
    path_pattern               = "/x/*"
    target_origin_id           = "apigw"
    viewer_protocol_policy     = "https-only"
    allowed_methods            = ["GET", "HEAD", "OPTIONS", "PUT", "POST", "PATCH", "DELETE"]
    cached_methods             = ["GET", "HEAD"]
    compress                   = true
    cache_policy_id            = data.aws_cloudfront_cache_policy.disabled.id
    origin_request_policy_id   = data.aws_cloudfront_origin_request_policy.all_but_host.id
    response_headers_policy_id = aws_cloudfront_response_headers_policy.this.id
  }

  restrictions {
    geo_restriction { restriction_type = "none" }
  }

  viewer_certificate {
    acm_certificate_arn      = aws_acm_certificate_validation.edge.certificate_arn
    ssl_support_method       = "sni-only"
    minimum_protocol_version = "TLSv1.3_2025"
  }

  # The origin custom header is owned by the rotation Lambda after creation.
  lifecycle { ignore_changes = [origin] }
}

# ------------------------------------------------------------- global WAF
resource "aws_wafv2_web_acl" "edge" {
  provider = aws.use1
  name     = "${local.n}-edge"
  scope    = "CLOUDFRONT"
  default_action {
    allow {}
  }

  dynamic "rule" {
    for_each = {
      AWSManagedRulesAmazonIpReputationList = 10
      AWSManagedRulesAnonymousIpList        = 20
      AWSManagedRulesKnownBadInputsRuleSet  = 30
      AWSManagedRulesCommonRuleSet          = 40
    }
    content {
      name     = rule.key
      priority = rule.value
      override_action {
        none {}
      }
      statement {
        managed_rule_group_statement {
          vendor_name = "AWS"
          name        = rule.key
        }
      }
      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = rule.key
        sampled_requests_enabled   = true
      }
    }
  }

  dynamic "rule" {
    for_each = var.edge_rate_limit > 0 ? [1] : []
    content {
      name     = "rate-per-ip"
      priority = 5
      action {
        block {}
      }
      statement {
        rate_based_statement {
          limit              = var.edge_rate_limit
          aggregate_key_type = "IP"
        }
      }
      visibility_config {
        cloudwatch_metrics_enabled = true
        metric_name                = "rate-per-ip"
        sampled_requests_enabled   = true
      }
    }
  }

  visibility_config {
    cloudwatch_metrics_enabled = true
    metric_name                = "${local.n}-edge"
    sampled_requests_enabled   = true
  }
}

resource "aws_cloudwatch_log_group" "waf_edge" {
  provider          = aws.use1
  name              = "aws-waf-logs-${local.n}-edge" # prefix required by WAF
  retention_in_days = 90
  kms_key_id        = aws_kms_key.edge_logs.arn
}

resource "aws_wafv2_web_acl_logging_configuration" "edge" {
  provider                = aws.use1
  resource_arn            = aws_wafv2_web_acl.edge.arn
  log_destination_configs = [aws_cloudwatch_log_group.waf_edge.arn]
  redacted_fields {
    single_header { name = "authorization" }
  }
  redacted_fields {
    single_header { name = "x-origin-verify" }
  }
}
