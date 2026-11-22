# ECS Fargate on Graviton (ARM64): ~20% cheaper per vCPU than x86; the
# multi-arch image runs unchanged on either. 3 tasks minimum, one per AZ,
# rebalanced automatically when an AZ recovers.

resource "aws_ecs_cluster" "this" {
  name = "${local.n}-${var.environment}"
  setting {
    name  = "containerInsights"
    value = "enabled" # standard Container Insights: enough for the dashboard, cheaper than "enhanced"
  }
}

resource "aws_ecs_cluster_capacity_providers" "this" {
  cluster_name       = aws_ecs_cluster.this.name
  capacity_providers = ["FARGATE"]
  default_capacity_provider_strategy {
    capacity_provider = "FARGATE"
    weight            = 1
  }
}

locals {
  hardening = {
    readonlyRootFilesystem = true
    user                   = "65532:65532"
    privileged             = false
    linuxParameters        = { capabilities = { drop = ["ALL"] }, initProcessEnabled = true }
  }
  log = { for s in local.ecs_families : s => {
    logDriver = "awslogs"
    options = {
      awslogs-group         = aws_cloudwatch_log_group.this[s].name
      awslogs-region        = var.region
      awslogs-stream-prefix = s
      mode                  = "non-blocking" # never block the app on log back-pressure
      max-buffer-size       = "4m"
    }
  } }
  db_env = [
    { name = "DB_WRITER_HOST", value = aws_rds_cluster.this.endpoint },
    { name = "DB_READER_HOST", value = aws_rds_cluster.this.reader_endpoint },
    { name = "DB_NAME", value = "soge" },
    { name = "DB_SSLMODE", value = "verify-full" },
  ]
}

resource "aws_ecs_task_definition" "api" {
  family                   = "${local.n}-api"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256 # small tasks: scaling out is visible sooner and costs less
  memory                   = 512
  execution_role_arn       = aws_iam_role.exec["api"].arn
  task_role_arn            = aws_iam_role.task["api"].arn
  runtime_platform {
    cpu_architecture        = "ARM64"
    operating_system_family = "LINUX"
  }
  container_definitions = jsonencode([merge(local.hardening, {
    name         = "api"
    image        = var.api_image
    essential    = true
    command      = ["serve"]
    portMappings = [{ containerPort = 8443, protocol = "tcp" }] # TLS 1.3 (end-to-end encryption)
    environment = concat(local.db_env, [
      { name = "TLS_ENABLED", value = "true" },
      { name = "DB_USER", value = "soge_app" },
      { name = "DB_MAX_CONNS", value = "10" },
      { name = "RATES_BUCKET", value = aws_s3_bucket.rates.bucket },
      { name = "AWS_REGION", value = var.region },
    ])
    secrets          = [{ name = "QUOTE_SIGNING_KEY", valueFrom = aws_secretsmanager_secret.this["quote"].arn }]
    healthCheck      = { command = ["/soge", "healthcheck"], interval = 15, timeout = 3, retries = 3, startPeriod = 10 }
    stopTimeout      = 30
    logConfiguration = local.log["api"]
    ulimits          = [{ name = "nofile", softLimit = 65536, hardLimit = 65536 }]
  })])
}

# One-shot migration task, run by CI before each deployment: the ONLY place
# where the RDS-managed admin secret is injected.
resource "aws_ecs_task_definition" "migrate" {
  family                   = "${local.n}-migrate"
  requires_compatibilities = ["FARGATE"]
  network_mode             = "awsvpc"
  cpu                      = 256
  memory                   = 512
  execution_role_arn       = aws_iam_role.exec["migrate"].arn
  task_role_arn            = aws_iam_role.task["migrate"].arn
  runtime_platform {
    cpu_architecture        = "ARM64"
    operating_system_family = "LINUX"
  }
  container_definitions = jsonencode([merge(local.hardening, {
    name        = "migrate"
    image       = var.api_image
    essential   = true
    command     = ["migrate"]
    environment = local.db_env
    secrets = [
      { name = "DB_ADMIN_USER", valueFrom = "${aws_rds_cluster.this.master_user_secret[0].secret_arn}:username::" },
      { name = "DB_ADMIN_PASSWORD", valueFrom = "${aws_rds_cluster.this.master_user_secret[0].secret_arn}:password::" },
    ]
    logConfiguration = local.log["migrate"]
  })])
}

resource "aws_ecs_service" "api" {
  name                               = "api"
  cluster                            = aws_ecs_cluster.this.id
  task_definition                    = aws_ecs_task_definition.api.arn
  desired_count                      = var.min_tasks
  launch_type                        = "FARGATE"
  platform_version                   = "LATEST"
  health_check_grace_period_seconds  = 30
  enable_execute_command             = false # no shell into production containers
  enable_ecs_managed_tags            = true
  propagate_tags                     = "SERVICE" # the 5 mandatory tags reach every task
  availability_zone_rebalancing      = "ENABLED"
  deployment_minimum_healthy_percent = 100 # never below capacity during a deployment
  deployment_maximum_percent         = 200

  deployment_circuit_breaker {
    enable   = true
    rollback = true
  }
  # Automatic rollback if the SLO alarms fire during a deployment.
  alarms {
    enable      = true
    rollback    = true
    alarm_names = [aws_cloudwatch_metric_alarm.alb_5xx.alarm_name, aws_cloudwatch_metric_alarm.alb_p95.alarm_name]
  }

  network_configuration {
    subnets          = local.subnet_ids["app"]
    security_groups  = [local.sg["api"]]
    assign_public_ip = false
  }
  load_balancer {
    target_group_arn = aws_lb_target_group.api.arn
    container_name   = "api"
    container_port   = 8443
  }
  lifecycle { ignore_changes = [desired_count] } # owned by autoscaling
  depends_on = [aws_lb_listener.https]
}

# ---------------------------------------------------------------- autoscaling
resource "aws_appautoscaling_target" "api" {
  service_namespace  = "ecs"
  scalable_dimension = "ecs:service:DesiredCount"
  resource_id        = "service/${aws_ecs_cluster.this.name}/${aws_ecs_service.api.name}"
  min_capacity       = var.min_tasks
  max_capacity       = var.max_tasks
}

resource "aws_appautoscaling_policy" "cpu" {
  name               = "api-cpu"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = "ecs"
  resource_id        = aws_appautoscaling_target.api.resource_id
  scalable_dimension = aws_appautoscaling_target.api.scalable_dimension
  target_tracking_scaling_policy_configuration {
    target_value       = 60
    scale_out_cooldown = 60
    scale_in_cooldown  = 300 # scale out fast, scale in slowly
    predefined_metric_specification { predefined_metric_type = "ECSServiceAverageCPUUtilization" }
  }
}

resource "aws_appautoscaling_policy" "requests" {
  name               = "api-requests"
  policy_type        = "TargetTrackingScaling"
  service_namespace  = "ecs"
  resource_id        = aws_appautoscaling_target.api.resource_id
  scalable_dimension = aws_appautoscaling_target.api.scalable_dimension
  target_tracking_scaling_policy_configuration {
    target_value       = 300 # requests per task per minute (~5 req/s): small tasks, scale-out visible in the load test
    scale_out_cooldown = 60
    scale_in_cooldown  = 300
    predefined_metric_specification {
      predefined_metric_type = "ALBRequestCountPerTarget"
      resource_label         = "${aws_lb.this.arn_suffix}/${aws_lb_target_group.api.arn_suffix}"
    }
  }
}
