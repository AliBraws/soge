# Security groups: SG-to-SG references only, explicit egress on every group
# (standalone rule resources: AWS's implicit allow-all egress is never created).
#
#   vpclink ─443─> alb ─8443 (TLS 1.3)─> api ─5432 (TLS 1.3)─> db
#   api, migrate ─443─> endpoints, S3 prefix list
#   db: no egress rule at all

locals {
  sgs = ["vpclink", "alb", "api", "migrate", "db", "endpoints"]
}

resource "aws_security_group" "this" {
  for_each               = toset(local.sgs)
  name                   = "${local.n}-${each.key}"
  description            = "${local.n} ${each.key}"
  vpc_id                 = aws_vpc.this.id
  revoke_rules_on_delete = true
  tags                   = { Name = "${local.n}-${each.key}" }
  lifecycle { create_before_destroy = true }
}

data "aws_ec2_managed_prefix_list" "s3" {
  name = "com.amazonaws.${var.region}.s3"
}

locals {
  sg = { for k, v in aws_security_group.this : k => v.id }

  sg_flows = {
    vpclink_alb       = { from = "vpclink", to = "alb", port = 443 }
    alb_api           = { from = "alb", to = "api", port = 8443 }
    api_db            = { from = "api", to = "db", port = 5432 }
    migrate_db        = { from = "migrate", to = "db", port = 5432 }
    api_endpoints     = { from = "api", to = "endpoints", port = 443 }
    migrate_endpoints = { from = "migrate", to = "endpoints", port = 443 }
  }
}

resource "aws_vpc_security_group_egress_rule" "flow" {
  for_each                     = local.sg_flows
  security_group_id            = local.sg[each.value.from]
  referenced_security_group_id = local.sg[each.value.to]
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
  description                  = each.key
}

resource "aws_vpc_security_group_ingress_rule" "flow" {
  for_each                     = local.sg_flows
  security_group_id            = local.sg[each.value.to]
  referenced_security_group_id = local.sg[each.value.from]
  ip_protocol                  = "tcp"
  from_port                    = each.value.port
  to_port                      = each.value.port
  description                  = each.key
}

resource "aws_vpc_security_group_egress_rule" "s3" {
  for_each          = toset(["api", "migrate"])
  security_group_id = local.sg[each.key]
  prefix_list_id    = data.aws_ec2_managed_prefix_list.s3.id
  ip_protocol       = "tcp"
  from_port         = 443
  to_port           = 443
  description       = "S3 gateway endpoint (ECR layers, rates snapshot)"
}
