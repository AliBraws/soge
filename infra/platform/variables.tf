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
  description = "One task per AZ minimum: losing an AZ leaves 2/3 of the capacity"
  type        = number
  default     = 3
}

variable "max_tasks" {
  type    = number
  default = 18
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
  description = "1 writer + N-1 readers, one per AZ. 2 = classic Multi-AZ; 3 = one instance in every AZ"
  type        = number
  default     = 3
  validation {
    condition     = var.aurora_instance_count >= 2 && var.aurora_instance_count <= 3
    error_message = "Between 2 (Multi-AZ) and 3 (one per AZ)."
  }
}

variable "aurora_max_acu" {
  type    = number
  default = 16
}

variable "deletion_protection" {
  description = "true in real life; false for the exercise so that terraform destroy cleans everything"
  type        = bool
  default     = false
}

variable "edge_rate_limit" {
  description = "WAF requests per IP per 5 min at the edge. 0 = off (load test from a single IP)"
  type        = number
  default     = 0
}

variable "alarm_email" {
  type    = string
  default = ""
}
