variable "region" {
  description = "Paris: data stays in France, 3 Availability Zones"
  type        = string
  default     = "eu-west-3"
}

variable "environment" {
  type    = string
  default = "prod"
}

variable "owner" {
  description = "Owner tag: GitHub login or team accountable for the resources (never a personal e-mail)"
  type        = string
}

variable "github_repository" {
  type    = string
  default = "OWNER/soge"
}

variable "hosted_zone_id" {
  description = "ID of the existing public Route 53 hosted zone (e.g. the zone of labs.athoria.fr). Referenced by ID: a name can exist twice."
  type        = string
  validation {
    condition     = can(regex("^Z[A-Z0-9]{5,31}$", var.hosted_zone_id))
    error_message = "Expected a Route 53 hosted zone ID (Z...)."
  }
}

variable "app_host" {
  description = "Public host label: <app_host>.<hosted zone> (soge.labs.athoria.fr)"
  type        = string
  default     = "soge"
}

variable "origin_host" {
  description = "Host label of the API Gateway origin (only CloudFront uses it)"
  type        = string
  default     = "o-4f2a"
}

variable "vpc_cidr" {
  type    = string
  default = "10.20.0.0/16"
}

variable "api_image" {
  description = "Image reference pinned BY DIGEST (set by CI: <repo>@sha256:...)"
  type        = string
  validation {
    condition     = can(regex("@sha256:[a-f0-9]{64}$", var.api_image))
    error_message = "api_image must be pinned by digest (…@sha256:<64 hex>), never by a mutable tag."
  }
}

variable "min_tasks" {
  description = "One small task per AZ: losing an AZ leaves 2/3 of the capacity (3 x 0.25 vCPU)"
  type        = number
  default     = 3
}

variable "max_tasks" {
  description = "Scaling ceiling, also a cost ceiling (6 x 0.25 vCPU = 1.5 vCPU)"
  type        = number
  default     = 6
}

variable "aurora_engine_version" {
  description = "Aurora PostgreSQL version supporting Serverless v2 in the region (aws rds describe-orderable-db-instance-options --db-instance-class db.serverless)"
  type        = string
  default     = "18.6"
  validation {
    condition     = can(regex("^[0-9]+\\.[0-9]+$", var.aurora_engine_version))
    error_message = "Use a full major.minor version, e.g. 18.6."
  }
}

variable "aurora_min_acu" {
  type    = number
  default = 0.5
}

variable "aurora_instance_count" {
  description = "1 writer + N-1 readers. 2 = Multi-AZ with automatic failover (default, cost-aware); 3 = one instance in every AZ"
  type        = number
  default     = 2
  validation {
    condition     = var.aurora_instance_count >= 2 && var.aurora_instance_count <= 3
    error_message = "Between 2 (Multi-AZ) and 3 (one per AZ)."
  }
}

variable "aurora_max_acu" {
  description = "Per-instance ceiling, also a cost ceiling (1 ACU ~ 2 GiB RAM)"
  type        = number
  default     = 2
}

variable "deletion_protection" {
  description = "true in real life; false for the exercise so that terraform destroy cleans everything"
  type        = bool
  default     = false
}

variable "edge_rate_limit" {
  description = "WAF: requests per client IP per 5 min (2000 = ~6.7 req/s sustained, far above a human trader). Above it, the IP is blocked at the edge. 0 disables the rule"
  type        = number
  default     = 2000
  validation {
    condition     = var.edge_rate_limit == 0 || (var.edge_rate_limit >= 10 && var.edge_rate_limit <= 2000000000)
    error_message = "edge_rate_limit must be 0 (disabled) or between 10 and 2e9 (AWS WAF bounds)."
  }
}

variable "api_rate_limit" {
  description = "API Gateway: requests per second for ALL clients together (burst = 2x). Hard ceiling on load and cost"
  type        = number
  default     = 50
}

variable "apigw_access_logs" {
  description = "API Gateway access logs. Requires the account-wide API Gateway CloudWatch role to already exist (not managed here: shared account)"
  type        = bool
  default     = false
}

variable "daily_budget_usd" {
  description = "AWS Budget on resources tagged Project=soge: e-mail at 80% and 100% of this daily amount"
  type        = number
  default     = 10
}

variable "alarm_email" {
  type    = string
  default = ""
}
