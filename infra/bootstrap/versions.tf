terraform {
  required_version = "~> 1.17"
  required_providers {
    aws = { source = "hashicorp/aws", version = "~> 6.73" }
  }
  # Chicken-and-egg: the first apply uses local state (this stack creates the
  # bucket). Then: cp backend.tf.example backend.tf && terraform init -migrate-state
}

provider "aws" {
  region = var.region
  default_tags { tags = local.tags }
}
