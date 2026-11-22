variable "region" {
  type    = string
  default = "eu-west-3"
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
  description = "owner/repo allowed to assume the CI roles"
  type        = string
  default     = "OWNER/soge"
  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$", var.github_repository))
    error_message = "Expected owner/repo."
  }
}

variable "github_sub_prefix" {
  description = "OIDC subject prefix of the repository, immutable format: repo:<owner>@<owner_id>/<repo>@<repo_id>"
  type        = string
  validation {
    condition     = can(regex("^repo:[A-Za-z0-9-]+@[0-9]+/[A-Za-z0-9._-]+@[0-9]+$", var.github_sub_prefix))
    error_message = "Use the immutable prefix returned by: gh api repos/<owner>/<repo>/actions/oidc/customization/sub --jq .sub_claim_prefix"
  }
}

variable "allow_destroy" {
  description = "Rehearsal only: let terraform destroy delete a non-empty state bucket and ECR repository"
  type        = bool
  default     = false
}

locals {
  name = "soge"
  # The 5 mandatory tags, applied to every taggable resource via default_tags.
  tags = {
    Project     = "soge"
    Environment = var.environment
    Owner       = var.owner
    ManagedBy   = "terraform"
    Repository  = "github.com/${var.github_repository}"
  }
}

check "mandatory_tags" {
  assert {
    condition     = alltrue([for k in ["Project", "Environment", "Owner", "ManagedBy", "Repository"] : try(length(local.tags[k]) > 0, false)])
    error_message = "The 5 mandatory tags must be set and non-empty."
  }
}
