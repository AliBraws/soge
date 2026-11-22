# Observability: logs (JSON, KMS-encrypted), metrics (AWS + EMF from the app),
# traces (X-Ray on API Gateway, trace id propagated to the ALB
# and logged by the API), SLO alarms wired to ECS deployment rollback.
#
# SLOs (docs/RUNBOOK.md):
#   availability  99.9 % of /x/* requests are not 5xx (30-day window)
#   latency       p95 < 300 ms at the ALB, p95 < 500 ms end-to-end at API Gateway
#   freshness     rates snapshot not older than 26 h on business days

resource "aws_sns_topic" "alarms" {
  name              = "${local.n}-alarms"
  kms_master_key_id = aws_kms_key.this["app"].arn # CMK: the AWS-managed key would not let CloudWatch publish
}

resource "aws_sns_topic_subscription" "email" {
  count     = var.alarm_email == "" ? 0 : 1
  topic_arn = aws_sns_topic.alarms.arn
  protocol  = "email"
  endpoint  = var.alarm_email
}

locals {
  alb_dim = { LoadBalancer = aws_lb.this.arn_suffix }
}

# ---- ALB: 5xx ratio (metric math) and p95 latency — also used for deploy rollback
resource "aws_cloudwatch_metric_alarm" "alb_5xx" {
  alarm_name          = "${local.n}-alb-5xx-ratio"
  alarm_description   = "More than 1% of requests answered 5xx (SLO burn)"
  comparison_operator = "GreaterThanThreshold"
  threshold           = 1
  evaluation_periods  = 3
  datapoints_to_alarm = 2
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
  ok_actions          = [aws_sns_topic.alarms.arn]
  metric_query {
    id          = "ratio"
    expression  = "100 * (e5 + t5) / MAX([req, 1])"
    label       = "5xx %"
    return_data = true
  }
  dynamic "metric_query" {
    for_each = { e5 = "HTTPCode_ELB_5XX_Count", t5 = "HTTPCode_Target_5XX_Count", req = "RequestCount" }
    content {
      id = metric_query.key
      metric {
        namespace   = "AWS/ApplicationELB"
        metric_name = metric_query.value
        dimensions  = local.alb_dim
        period      = 60
        stat        = "Sum"
      }
    }
  }
}

resource "aws_cloudwatch_metric_alarm" "alb_p95" {
  alarm_name          = "${local.n}-alb-p95"
  alarm_description   = "Target p95 latency above 300 ms"
  namespace           = "AWS/ApplicationELB"
  metric_name         = "TargetResponseTime"
  dimensions          = local.alb_dim
  extended_statistic  = "p95"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  threshold           = 0.3
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "apigw_5xx" {
  alarm_name          = "${local.n}-apigw-5xx"
  namespace           = "AWS/ApiGateway"
  metric_name         = "5XXError"
  dimensions          = { ApiName = aws_api_gateway_rest_api.this.name, Stage = "live" }
  statistic           = "Average"
  period              = 60
  evaluation_periods  = 5
  datapoints_to_alarm = 3
  threshold           = 0.01
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "fn_errors" {
  for_each            = local.functions
  alarm_name          = "${local.n}-fn-${each.key}-errors"
  namespace           = "AWS/Lambda"
  metric_name         = "Errors"
  dimensions          = { FunctionName = aws_lambda_function.fn[each.key].function_name }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 1
  threshold           = startswith(each.key, "authorizer") ? 10 : 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "aurora_acu" {
  alarm_name          = "${local.n}-aurora-acu-high"
  alarm_description   = "Aurora close to max ACU: raise aurora_max_acu or add read scaling"
  namespace           = "AWS/RDS"
  metric_name         = "ACUUtilization"
  dimensions          = { DBClusterIdentifier = aws_rds_cluster.this.cluster_identifier }
  statistic           = "Average"
  period              = 300
  evaluation_periods  = 3
  threshold           = 85
  comparison_operator = "GreaterThanThreshold"
  alarm_actions       = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_metric_alarm" "rates_stale" {
  alarm_name          = "${local.n}-rates-fetch-failures"
  alarm_description   = "API cannot load the rates snapshot (serving last known / seed rates)"
  namespace           = "Soge"
  metric_name         = "RatesFetchFailures"
  dimensions          = { Service = "soge-api" }
  statistic           = "Sum"
  period              = 300
  evaluation_periods  = 3
  threshold           = 0
  comparison_operator = "GreaterThanThreshold"
  treat_missing_data  = "notBreaching"
  alarm_actions       = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_composite_alarm" "slo" {
  alarm_name        = "${local.n}-slo-breach"
  alarm_description = "Customer-facing SLO at risk"
  alarm_rule        = "ALARM(${aws_cloudwatch_metric_alarm.alb_5xx.alarm_name}) OR ALARM(${aws_cloudwatch_metric_alarm.apigw_5xx.alarm_name})"
  alarm_actions     = [aws_sns_topic.alarms.arn]
}

resource "aws_cloudwatch_dashboard" "this" {
  dashboard_name = "${local.n}-${var.environment}"
  dashboard_body = jsonencode({
    widgets = [
      { type = "metric", x = 0, y = 0, width = 12, height = 6, properties = {
        title   = "Edge: requests & 5xx (API Gateway public)", region = var.region, stat = "Sum", period = 60,
        metrics = [["AWS/ApiGateway", "Count", "ApiName", aws_api_gateway_rest_api.this.name, "Stage", "live"], [".", "5XXError", ".", ".", ".", "."], [".", "4XXError", ".", ".", ".", "."]]
      } },
      { type = "metric", x = 12, y = 0, width = 12, height = 6, properties = {
        title   = "Latency p50/p95/p99 (ALB target)", region = var.region, period = 60,
        metrics = [for p in ["p50", "p95", "p99"] : ["AWS/ApplicationELB", "TargetResponseTime", "LoadBalancer", aws_lb.this.arn_suffix, { stat = p }]]
      } },
      { type = "metric", x = 0, y = 6, width = 12, height = 6, properties = {
        title   = "ECS running tasks (autoscaling)", region = var.region, stat = "Average", period = 60,
        metrics = [["ECS/ContainerInsights", "RunningTaskCount", "ClusterName", aws_ecs_cluster.this.name, "ServiceName", "api"]]
      } },
      { type = "metric", x = 12, y = 6, width = 12, height = 6, properties = {
        title   = "ECS CPU %", region = var.region, stat = "Average", period = 60,
        metrics = [["AWS/ECS", "CPUUtilization", "ClusterName", aws_ecs_cluster.this.name, "ServiceName", "api"]]
      } },
      { type = "metric", x = 0, y = 12, width = 12, height = 6, properties = {
        title   = "Aurora ACU / connections", region = var.region, stat = "Average", period = 60,
        metrics = [["AWS/RDS", "ServerlessDatabaseCapacity", "DBClusterIdentifier", aws_rds_cluster.this.cluster_identifier], [".", "DatabaseConnections", ".", "."]]
      } },
      { type = "metric", x = 12, y = 12, width = 12, height = 6, properties = {
        title   = "Business: deals executed / rate fetch failures (EMF)", region = var.region, stat = "Sum", period = 60,
        metrics = [["Soge", "DealsExecuted", "Service", "soge-api"], [".", "RatesFetchFailures", ".", "."]]
      } },
      { type = "metric", x = 0, y = 18, width = 24, height = 6, properties = {
        title   = "WAF blocked requests", region = var.region, stat = "Sum", period = 60,
        metrics = [["AWS/WAFV2", "BlockedRequests", "WebACL", aws_wafv2_web_acl.edge.name, "Rule", "ALL", "Region", "us-east-1"]]
      } },
    ]
  })
}
