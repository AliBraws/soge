# VPC endpoints: the workload reaches AWS APIs privately. Endpoint policies form
# a data perimeter: only principals and resources of THIS account (exfiltration
# to a foreign bucket/secret is impossible even with stolen credentials).

locals {
  # Each endpoint only allows the exact API calls the workload makes, on this
  # account's resources, by this account's principals.
  endpoint_policies = {
    "ecr.api" = [
      { actions = ["ecr:GetAuthorizationToken"], resources = ["*"] }, # no resource type exists for this action
      { actions = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"], resources = [local.ecr_repo_arn] },
    ]
    "ecr.dkr" = [
      { actions = ["ecr:BatchGetImage", "ecr:GetDownloadUrlForLayer"], resources = [local.ecr_repo_arn] },
    ]
    logs = [
      { actions = ["logs:CreateLogStream", "logs:PutLogEvents"], resources = [for s in ["api", "migrate"] : "${aws_cloudwatch_log_group.this[s].arn}:*"] },
    ]
    secretsmanager = [
      # ECS injects the quote key (api) and the RDS-managed admin secret (migrate) at task start
      { actions = ["secretsmanager:GetSecretValue"], resources = [aws_secretsmanager_secret.this["quote"].arn, aws_rds_cluster.this.master_user_secret[0].secret_arn] },
    ]
  }
}

resource "aws_vpc_endpoint" "interface" {
  for_each            = local.endpoint_policies
  vpc_id              = aws_vpc.this.id
  service_name        = "com.amazonaws.${var.region}.${each.key}"
  vpc_endpoint_type   = "Interface"
  subnet_ids          = local.subnet_ids["endpoints"]
  security_group_ids  = [local.sg["endpoints"]]
  private_dns_enabled = true
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [for st in each.value : {
      Effect    = "Allow"
      Principal = { AWS = local.account_id } # this account only (resource-policy principal, not a wildcard)
      Action    = st.actions
      Resource  = st.resources
    }]
  })
  tags = { Name = "${local.n}-${each.key}" }
}

locals {
  ecr_repo_arn = "arn:${local.partition}:ecr:${var.region}:${local.account_id}:repository/${local.n}/api"
}

resource "aws_vpc_endpoint" "s3" {
  vpc_id            = aws_vpc.this.id
  service_name      = "com.amazonaws.${var.region}.s3"
  vpc_endpoint_type = "Gateway"
  route_table_ids   = [aws_route_table.tier["app"].id]
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "RatesSnapshotOnly"
        Effect    = "Allow"
        Principal = { AWS = local.account_id }
        Action    = ["s3:GetObject", "s3:PutObject"]
        Resource  = "${aws_s3_bucket.rates.arn}/rates/latest.json"
      },
      {
        # ECR stores layers in this AWS-owned bucket; the object keys are not ours,
        # so the trailing /* is the narrowest possible scope.
        Sid       = "EcrLayers"
        Effect    = "Allow"
        Principal = { AWS = local.account_id }
        Action    = "s3:GetObject"
        Resource  = "arn:aws:s3:::prod-${var.region}-starport-layer-bucket/*"
      },
    ]
  })
  tags = { Name = "${local.n}-s3" }
}
