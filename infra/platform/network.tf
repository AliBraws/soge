# Dedicated VPC (the account's default VPC is never used: it has public subnets
# and an internet gateway by design).
#
# 3 AZs x 4 tiers. No internet gateway, no NAT, no public IP: there is NO route
# out of this VPC. AWS APIs are reached through VPC endpoints.
#
#   tier       per-AZ   route table               hosts
#   ingress    /24      local                     internal ALB, API Gateway VPC link ENIs
#   app        /20      local + S3 gateway        Fargate tasks
#   endpoints  /24      local                     interface endpoints
#   data       /24      local only (isolated)     Aurora

locals {
  tiers = {
    ingress   = [for i in range(3) : cidrsubnet(var.vpc_cidr, 8, i)]      # 10.20.0-2.0/24
    endpoints = [for i in range(3) : cidrsubnet(var.vpc_cidr, 8, 4 + i)]  # 10.20.4-6.0/24
    app       = [for i in range(3) : cidrsubnet(var.vpc_cidr, 4, 1 + i)]  # 10.20.16.0/20, 32.0/20, 48.0/20
    data      = [for i in range(3) : cidrsubnet(var.vpc_cidr, 8, 64 + i)] # 10.20.64-66.0/24
  }
  subnets = merge([for tier, cidrs in local.tiers : {
    for i, c in cidrs : "${tier}-${i}" => { tier = tier, cidr = c, az = local.azs[i] }
  }]...)
  subnet_ids = { for tier in keys(local.tiers) : tier => [for i in range(3) : aws_subnet.this["${tier}-${i}"].id] }
}

resource "aws_vpc" "this" {
  cidr_block           = var.vpc_cidr
  enable_dns_support   = true
  enable_dns_hostnames = true # required by interface endpoints' private DNS
  tags                 = { Name = "${local.n}-${var.environment}" }
}

# Lock the defaults: nothing can silently use them.
resource "aws_default_security_group" "this" {
  vpc_id = aws_vpc.this.id
  tags   = { Name = "${local.n}-default-unused" }
}

resource "aws_default_route_table" "this" {
  default_route_table_id = aws_vpc.this.default_route_table_id
  tags                   = { Name = "${local.n}-default-unused" }
}

resource "aws_default_network_acl" "this" {
  default_network_acl_id = aws_vpc.this.default_network_acl_id
  tags                   = { Name = "${local.n}-default-unused" } # no rule = deny all; every subnet has its own NACL
  lifecycle { ignore_changes = [subnet_ids] }
}

resource "aws_subnet" "this" {
  for_each                = local.subnets
  vpc_id                  = aws_vpc.this.id
  cidr_block              = each.value.cidr
  availability_zone       = each.value.az
  map_public_ip_on_launch = false
  tags                    = { Name = "${local.n}-${each.key}", Tier = each.value.tier }
}

resource "aws_route_table" "tier" {
  for_each = local.tiers
  vpc_id   = aws_vpc.this.id
  tags     = { Name = "${local.n}-${each.key}" }
}

resource "aws_route_table_association" "this" {
  for_each       = local.subnets
  subnet_id      = aws_subnet.this[each.key].id
  route_table_id = aws_route_table.tier[each.value.tier].id
}

# ------------------------------------------------------------------- flow logs
resource "aws_flow_log" "this" {
  vpc_id                   = aws_vpc.this.id
  traffic_type             = "ALL"
  log_destination_type     = "cloud-watch-logs"
  log_destination          = aws_cloudwatch_log_group.this["flow"].arn
  iam_role_arn             = aws_iam_role.flow.arn
  max_aggregation_interval = 60
}

resource "aws_iam_role" "flow" {
  name                 = "${local.n}-flow-logs"
  permissions_boundary = local.boundary_arn
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "vpc-flow-logs.amazonaws.com" }
      Action    = "sts:AssumeRole"
      Condition = { StringEquals = { "aws:SourceAccount" = local.account_id } } # confused-deputy protection
    }]
  })
}

resource "aws_iam_role_policy" "flow" {
  role = aws_iam_role.flow.id
  policy = jsonencode({
    Version   = "2012-10-17"
    Statement = [{ Effect = "Allow", Action = ["logs:CreateLogStream", "logs:PutLogEvents", "logs:DescribeLogStreams"], Resource = "${aws_cloudwatch_log_group.this["flow"].arn}:*" }]
  })
}
