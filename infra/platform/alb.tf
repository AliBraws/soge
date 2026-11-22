# Internal ALB: reachable only from the API Gateway VPC link security group.
# TLS 1.3 only (post-quantum hybrid key exchange), HTTP/2, strict desync
# mitigation, invalid headers dropped. Re-encrypts to the tasks in TLS 1.3.
# No ALB access logs: ELB log delivery only supports SSE-S3, not a CMK; the API
# Gateway access log (KMS) records every request first.

resource "aws_lb" "this" {
  name                       = "${local.n}-${var.environment}"
  internal                   = true
  load_balancer_type         = "application"
  subnets                    = local.subnet_ids["ingress"]
  security_groups            = [local.sg["alb"]]
  enable_http2               = true
  drop_invalid_header_fields = true
  desync_mitigation_mode     = "strictest"
  idle_timeout               = 60
  enable_deletion_protection = var.deletion_protection
}

resource "aws_lb_target_group" "api" {
  name                          = "${local.n}-api"
  port                          = 8443
  protocol                      = "HTTPS" # ALB -> task re-encrypted (TLS 1.3)
  protocol_version              = "HTTP1"
  target_type                   = "ip"
  vpc_id                        = aws_vpc.this.id
  deregistration_delay          = 20                           # < app shutdown grace (25 s) < ECS stopTimeout (30 s)
  load_balancing_algorithm_type = "least_outstanding_requests" # (incompatible with slow_start)
  health_check {
    protocol            = "HTTPS"
    path                = "/healthz" # liveness only: a DB failover must not kill healthy tasks
    matcher             = "200"
    interval            = 10
    timeout             = 3
    healthy_threshold   = 2
    unhealthy_threshold = 3
  }
}

resource "aws_lb_listener" "https" {
  load_balancer_arn = aws_lb.this.arn
  port              = 443
  protocol          = "HTTPS"
  ssl_policy        = "ELBSecurityPolicy-TLS13-1-2-Res-PQ-2025-09" # TLS 1.3 + restricted TLS 1.2 (ECDHE, AES-GCM), PQ: the API Gateway integration client cannot negotiate TLS 1.3 (ADR-013)
  certificate_arn   = aws_acm_certificate_validation.regional.certificate_arn
  default_action {
    type             = "forward"
    target_group_arn = aws_lb_target_group.api.arn
  }
}
