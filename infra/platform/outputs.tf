output "url" { value = "https://${local.app_fqdn}" }
output "cloudfront_id" { value = aws_cloudfront_distribution.this.id }
output "ecs_cluster" { value = aws_ecs_cluster.this.name }
output "migrate_task_definition" { value = aws_ecs_task_definition.migrate.arn }
output "migrate_network" {
  value = { subnets = local.subnet_ids["app"], security_groups = [local.sg["migrate"]] }
}
output "dashboard" { value = "https://${var.region}.console.aws.amazon.com/cloudwatch/home#dashboards/dashboard/${aws_cloudwatch_dashboard.this.dashboard_name}" }
