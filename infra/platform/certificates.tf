# Wildcard certificates ONLY: every public certificate is published in the
# Certificate Transparency logs, a named one would reveal the service on crt.sh.
# ECDSA P-256, DNS-validated, renewed automatically by ACM.

resource "aws_acm_certificate" "regional" { # API Gateway custom domain + internal ALB
  domain_name       = "*.${local.domain}"
  validation_method = "DNS"
  key_algorithm     = "EC_prime256v1"
  lifecycle { create_before_destroy = true }
}

resource "aws_acm_certificate" "edge" { # CloudFront (must be in us-east-1)
  provider          = aws.use1
  domain_name       = "*.${local.domain}"
  validation_method = "DNS"
  key_algorithm     = "EC_prime256v1"
  lifecycle { create_before_destroy = true }
}

# Same wildcard, same account => the same validation CNAME serves both certificates.
resource "aws_route53_record" "validation" {
  zone_id         = data.aws_route53_zone.public.zone_id
  name            = one(aws_acm_certificate.regional.domain_validation_options).resource_record_name
  type            = one(aws_acm_certificate.regional.domain_validation_options).resource_record_type
  records         = [one(aws_acm_certificate.regional.domain_validation_options).resource_record_value]
  ttl             = 300
  allow_overwrite = true
}

resource "aws_acm_certificate_validation" "regional" {
  certificate_arn         = aws_acm_certificate.regional.arn
  validation_record_fqdns = [aws_route53_record.validation.fqdn]
}

resource "aws_acm_certificate_validation" "edge" {
  provider                = aws.use1
  certificate_arn         = aws_acm_certificate.edge.arn
  validation_record_fqdns = [aws_route53_record.validation.fqdn]
}
