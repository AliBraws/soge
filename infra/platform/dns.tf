# Two public names: the entry point (soge.<zone>, alias to CloudFront, IPv4 + IPv6)
# and the API origin (only useful with the rotating origin-verify header).
resource "aws_route53_record" "app" {
  for_each = toset(["A", "AAAA"])
  zone_id  = data.aws_route53_zone.public.zone_id
  name     = local.app_fqdn
  type     = each.key
  alias {
    name                   = aws_cloudfront_distribution.this.domain_name
    zone_id                = aws_cloudfront_distribution.this.hosted_zone_id
    evaluate_target_health = false
  }
}

resource "aws_route53_record" "origin" {
  zone_id = data.aws_route53_zone.public.zone_id
  name    = local.origin_fqdn
  type    = "A"
  alias {
    name                   = aws_api_gateway_domain_name.this.regional_domain_name
    zone_id                = aws_api_gateway_domain_name.this.regional_zone_id
    evaluate_target_health = true
  }
}
