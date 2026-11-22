# Cost guardrail: a daily budget on everything tagged Project=soge, with e-mail
# alerts at 80% (actual) and 100% (actual). Together with the hard ceilings
# (WAF per-IP rate, API Gateway throttle, ECS max tasks, Aurora max ACU, Lambda
# reserved concurrency), a traffic spike can neither scale the bill nor go unnoticed.
# Prerequisite (once per account): activate the "Project" cost allocation tag.
resource "aws_budgets_budget" "daily" {
  name         = "${local.n}-daily"
  budget_type  = "COST"
  limit_amount = tostring(var.daily_budget_usd)
  limit_unit   = "USD"
  time_unit    = "DAILY"

  cost_filter {
    name   = "TagKeyValue"
    values = [format("user:Project$%s", local.n)]
  }

  dynamic "notification" {
    for_each = var.alarm_email == "" ? [] : [80, 100]
    content {
      comparison_operator        = "GREATER_THAN"
      threshold                  = notification.value
      threshold_type             = "PERCENTAGE"
      notification_type          = "ACTUAL"
      subscriber_email_addresses = [var.alarm_email]
    }
  }
}
