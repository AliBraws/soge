data "aws_caller_identity" "this" {}
data "aws_partition" "this" {}

data "aws_availability_zones" "azs" {
  state = "available"
  filter {
    name   = "opt-in-status"
    values = ["opt-in-not-required"]
  }
}

data "aws_route53_zone" "public" {
  zone_id = var.hosted_zone_id
}

locals {
  n          = "soge"
  account_id = data.aws_caller_identity.this.account_id
  partition  = data.aws_partition.this.partition
  azs        = slice(data.aws_availability_zones.azs.names, 0, 3)

  domain        = trimsuffix(data.aws_route53_zone.public.name, ".")
  app_fqdn      = "${var.app_host}.${local.domain}"
  origin_fqdn   = "${var.origin_host}.${local.domain}"
  upstream_host = "i-7c1d.${local.domain}" # TLS SNI/Host API Gateway -> ALB; no DNS record needed

  # The 5 mandatory tags (default_tags on every provider).
  tags = {
    Project     = "soge"
    Environment = var.environment
    Owner       = var.owner
    ManagedBy   = "terraform"
    Repository  = "github.com/${var.github_repository}"
  }

  # Every IAM role created here carries the bootstrap permissions boundary.
  boundary_arn = "arn:${local.partition}:iam::${local.account_id}:policy/${local.n}-boundary"
}

# Lambdas (outside the VPC: they only call AWS APIs and the ECB feed)
locals {
  functions = {
    authorizer     = { file = "authorizer", env = { REQUIRE_ORIGIN_VERIFY = "true" }, secrets = ["jwt", "origin"] }
    issuer         = { file = "issuer", env = {}, secrets = ["jwt"] }
    rotator_jwt    = { file = "rotator", env = { SECRET_KIND = "jwt" }, secrets = ["jwt"] }
    rotator_origin = { file = "rotator", env = { SECRET_KIND = "origin", ORIGIN_ID = "apigw" }, secrets = ["origin"] }
    rates_sync     = { file = "rates_sync", env = {}, secrets = [] }
  }
}


check "mandatory_tags" {
  assert {
    condition     = alltrue([for k in ["Project", "Environment", "Owner", "ManagedBy", "Repository"] : try(length(local.tags[k]) > 0, false)])
    error_message = "The 5 mandatory tags must be set and non-empty."
  }
}
