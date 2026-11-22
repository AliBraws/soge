provider "aws" {
  region = var.region
  default_tags { tags = local.tags }
}

# CloudFront certificate and CloudFront-scoped WAF must live in us-east-1.
provider "aws" {
  alias  = "use1"
  region = "us-east-1"
  default_tags { tags = local.tags }
}
