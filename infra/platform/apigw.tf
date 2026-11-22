# API Gateway REST (regional), the only flavour that combines a TLS 1.3-only
# policy, WAF support and Lambda REQUEST authorizers.
#   * custom domain only (default execute-api endpoint disabled), STRICT mode
#   * Lambda authorizer: origin-verify on every route + JWT on /x/q and /x/d
#   * VPC link v2 straight to the internal ALB (no NLB in between)

resource "aws_apigatewayv2_vpc_link" "this" {
  name               = "${local.n}-${var.environment}"
  subnet_ids         = local.subnet_ids["ingress"]
  security_group_ids = [local.sg["vpclink"]]
}

resource "aws_api_gateway_rest_api" "this" {
  name                         = local.n
  description                  = "soge"
  disable_execute_api_endpoint = true
  security_policy              = "SecurityPolicy_TLS13_1_3_2025_09"
  endpoint_access_mode         = "STRICT"
  endpoint_configuration { types = ["REGIONAL"] }
}

resource "aws_api_gateway_resource" "x" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "x"
}

resource "aws_api_gateway_resource" "leaf" {
  for_each    = toset(["s", "q", "d"])
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_resource.x.id
  path_part   = each.key
}

resource "aws_api_gateway_resource" "proxy" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  parent_id   = aws_api_gateway_rest_api.this.root_resource_id
  path_part   = "{proxy+}"
}

# ---------------------------------------------------------------- authorizers
# Same Lambda, two identity sources: "edge" = origin-verify only (UI, session),
# "jwt" = origin-verify + bearer token (quotes, deals).
resource "aws_api_gateway_authorizer" "this" {
  for_each = {
    edge = { identity = "method.request.header.X-Origin-Verify", ttl = 300 }
    jwt  = { identity = "method.request.header.Authorization,method.request.header.X-Origin-Verify", ttl = 60 }
  }
  name                             = each.key
  rest_api_id                      = aws_api_gateway_rest_api.this.id
  type                             = "REQUEST"
  authorizer_uri                   = aws_lambda_function.fn["authorizer"].invoke_arn
  identity_source                  = each.value.identity
  authorizer_result_ttl_in_seconds = each.value.ttl # JWT cache < token TTL (300 s)
}

resource "aws_lambda_permission" "authorizer" {
  statement_id  = "apigw-authorizer"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.fn["authorizer"].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/authorizers/*"
}

resource "aws_lambda_permission" "issuer" {
  statement_id  = "apigw-issuer"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.fn["issuer"].function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.this.execution_arn}/live/POST/x/s"
}

# ------------------------------------------------------- routes -> backends
locals {
  routes = {
    ui_root  = { resource = aws_api_gateway_rest_api.this.root_resource_id, method = "GET", target = "alb", auth = "edge", path = "/" }
    ui_files = { resource = aws_api_gateway_resource.proxy.id, method = "GET", target = "alb", auth = "edge", path = "/{proxy}" }
    quote    = { resource = aws_api_gateway_resource.leaf["q"].id, method = "GET", target = "alb", auth = "jwt", path = "/x/q" }
    blotter  = { resource = aws_api_gateway_resource.leaf["d"].id, method = "GET", target = "alb", auth = "jwt", path = "/x/d" }
    execute  = { resource = aws_api_gateway_resource.leaf["d"].id, method = "POST", target = "alb", auth = "jwt", path = "/x/d" }
    session  = { resource = aws_api_gateway_resource.leaf["s"].id, method = "POST", target = "issuer", auth = "edge", path = "" }
  }
}

resource "aws_api_gateway_method" "this" {
  for_each           = local.routes
  rest_api_id        = aws_api_gateway_rest_api.this.id
  resource_id        = each.value.resource
  http_method        = each.value.method
  authorization      = "CUSTOM"
  authorizer_id      = aws_api_gateway_authorizer.this[each.value.auth].id
  request_parameters = each.key == "ui_files" ? { "method.request.path.proxy" = true } : {}
}

resource "aws_api_gateway_integration" "this" {
  for_each                = local.routes
  rest_api_id             = aws_api_gateway_rest_api.this.id
  resource_id             = each.value.resource
  http_method             = aws_api_gateway_method.this[each.key].http_method
  type                    = each.value.target == "issuer" ? "AWS_PROXY" : "HTTP_PROXY"
  integration_http_method = each.value.target == "issuer" ? "POST" : each.value.method
  uri                     = each.value.target == "issuer" ? aws_lambda_function.fn["issuer"].invoke_arn : "https://${local.upstream_host}${each.value.path}"
  connection_type         = each.value.target == "issuer" ? "INTERNET" : "VPC_LINK"
  connection_id           = each.value.target == "issuer" ? null : aws_apigatewayv2_vpc_link.this.id
  integration_target      = each.value.target == "issuer" ? null : aws_lb.this.arn
  timeout_milliseconds    = 10000
  request_parameters = each.value.target == "issuer" ? {} : merge(
    each.key == "ui_files" ? { "integration.request.path.proxy" = "method.request.path.proxy" } : {},
    # Identity comes from the authorizer result; any client-sent X-Sub is overwritten.
    each.value.auth == "jwt" ? { "integration.request.header.X-Sub" = "context.authorizer.principalId" } : {},
    # The origin-verify secret stops here: it never reaches the backend.
    { "integration.request.header.X-Origin-Verify" = "''" },
  )
}

# Uniform, information-free error bodies.
resource "aws_api_gateway_gateway_response" "this" {
  for_each      = toset(["UNAUTHORIZED", "ACCESS_DENIED", "DEFAULT_4XX", "DEFAULT_5XX", "THROTTLED"])
  rest_api_id   = aws_api_gateway_rest_api.this.id
  response_type = each.key
  response_templates = {
    "application/json" = "{\"error\":\"$context.error.responseType\",\"request_id\":\"$context.requestId\"}"
  }
}

resource "aws_api_gateway_deployment" "this" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  triggers = {
    redeploy = sha1(jsonencode([
      aws_api_gateway_resource.x, aws_api_gateway_resource.leaf, aws_api_gateway_resource.proxy,
      aws_api_gateway_method.this, aws_api_gateway_integration.this, aws_api_gateway_authorizer.this,
      aws_api_gateway_gateway_response.this,
    ]))
  }
  lifecycle { create_before_destroy = true }
}

resource "aws_api_gateway_stage" "live" {
  rest_api_id          = aws_api_gateway_rest_api.this.id
  deployment_id        = aws_api_gateway_deployment.this.id
  stage_name           = "live"
  xray_tracing_enabled = false # cost: tracing is not needed for this scope
  # REST API access logs need the ACCOUNT-WIDE "CloudWatch role" setting of API
  # Gateway. This is a shared account: we do not change account-level settings.
  # Enable only if that role already exists (aws apigateway get-account).
  dynamic "access_log_settings" {
    for_each = var.apigw_access_logs ? [1] : []
    content {
      destination_arn = aws_cloudwatch_log_group.this["apigw"].arn
      format = jsonencode({
        requestId            = "$context.requestId", ip = "$context.identity.sourceIp", method = "$context.httpMethod"
        path                 = "$context.path", status = "$context.status", latencyMs = "$context.responseLatency"
        integrationLatencyMs = "$context.integration.latency", authorizerError = "$context.authorizer.error"
        tlsVersion           = "$context.tlsVersion", sub = "$context.authorizer.principalId"
      })
    }
  }
}

resource "aws_api_gateway_method_settings" "all" {
  rest_api_id = aws_api_gateway_rest_api.this.id
  stage_name  = aws_api_gateway_stage.live.stage_name
  method_path = "*/*"
  settings {
    metrics_enabled    = true
    logging_level      = "OFF" # execution logs would land in unencrypted auto-created groups; access logs (KMS) are enough
    data_trace_enabled = false # never log request/response bodies
    # Global ceiling for the whole API (all clients together): bounds backend
    # load and the cost of a request flood. Above it: 429 + Retry-After.
    throttling_rate_limit  = var.api_rate_limit
    throttling_burst_limit = var.api_rate_limit * 2
  }
}

resource "aws_api_gateway_domain_name" "this" {
  domain_name              = local.origin_fqdn
  regional_certificate_arn = aws_acm_certificate_validation.regional.certificate_arn
  security_policy          = "SecurityPolicy_TLS13_1_3_2025_09"
  endpoint_access_mode     = "STRICT"
  endpoint_configuration { types = ["REGIONAL"] }
}

resource "aws_api_gateway_base_path_mapping" "this" {
  api_id      = aws_api_gateway_rest_api.this.id
  stage_name  = aws_api_gateway_stage.live.stage_name
  domain_name = aws_api_gateway_domain_name.this.domain_name
}

# Account-level setting: the role API Gateway uses to write access logs.

