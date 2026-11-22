# Network ACLs: stateless guardrail per tier, in addition to security groups
# (the primary control). If a security group is ever mis-edited, the data tier
# still only speaks PostgreSQL with the app tier.
#
# The app tier allows 443 out to 0.0.0.0/0 only because the S3 gateway endpoint
# uses S3 public IP ranges (NACLs cannot reference prefix lists). There is no
# route to the internet, so nothing can actually leave the VPC.

locals {
  nacl_rules = {
    data = {
      ingress = concat(
        [for i, c in local.tiers.app : { n = 100 + i, cidr = c, from = 5432, to = 5432 }],
        [for i, c in local.tiers.data : { n = 200 + i, cidr = c, from = 5432, to = 5432 }],
      )
      egress = concat(
        [for i, c in local.tiers.app : { n = 100 + i, cidr = c, from = 1024, to = 65535 }],
        [for i, c in local.tiers.data : { n = 200 + i, cidr = c, from = 1024, to = 65535 }],
      )
    }
    app = {
      ingress = concat(
        [for i, c in local.tiers.ingress : { n = 100 + i, cidr = c, from = 8443, to = 8443 }],
        [{ n = 300, cidr = "0.0.0.0/0", from = 1024, to = 65535 }], # return traffic: DB, endpoints, S3
      )
      egress = concat(
        [{ n = 100, cidr = "0.0.0.0/0", from = 443, to = 443 }],
        [for i, c in local.tiers.data : { n = 200 + i, cidr = c, from = 5432, to = 5432 }],
        [for i, c in local.tiers.ingress : { n = 300 + i, cidr = c, from = 1024, to = 65535 }],
      )
    }
    ingress = {
      ingress = concat(
        [for i, c in local.tiers.ingress : { n = 100 + i, cidr = c, from = 443, to = 443 }], # VPC link ENIs -> ALB
        [for i, c in local.tiers.app : { n = 200 + i, cidr = c, from = 1024, to = 65535 }],
        [for i, c in local.tiers.ingress : { n = 300 + i, cidr = c, from = 1024, to = 65535 }],
      )
      egress = concat(
        [for i, c in local.tiers.app : { n = 100 + i, cidr = c, from = 8443, to = 8443 }],
        [for i, c in local.tiers.ingress : { n = 200 + i, cidr = c, from = 443, to = 443 }],
        [for i, c in local.tiers.ingress : { n = 300 + i, cidr = c, from = 1024, to = 65535 }],
      )
    }
    endpoints = {
      ingress = [for i, c in local.tiers.app : { n = 100 + i, cidr = c, from = 443, to = 443 }]
      egress  = [for i, c in local.tiers.app : { n = 100 + i, cidr = c, from = 1024, to = 65535 }]
    }
  }

  nacl_flat = merge([for tier, dirs in local.nacl_rules : merge(
    { for r in dirs.ingress : "${tier}-in-${r.n}" => merge(r, { tier = tier, egress = false }) },
    { for r in dirs.egress : "${tier}-out-${r.n}" => merge(r, { tier = tier, egress = true }) },
  )]...)
}

resource "aws_network_acl" "tier" {
  for_each   = local.nacl_rules
  vpc_id     = aws_vpc.this.id
  subnet_ids = local.subnet_ids[each.key]
  tags       = { Name = "${local.n}-${each.key}" }
}

resource "aws_network_acl_rule" "this" {
  for_each       = local.nacl_flat
  network_acl_id = aws_network_acl.tier[each.value.tier].id
  rule_number    = each.value.n
  egress         = each.value.egress
  protocol       = "tcp"
  rule_action    = "allow"
  cidr_block     = each.value.cidr
  from_port      = each.value.from
  to_port        = each.value.to
}
