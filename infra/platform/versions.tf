terraform {
  # >= 1.11: write-only arguments fed by ephemeral resources; pinned to the
  # current minor line.
  required_version = "~> 1.17"
  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 6.73" }   # TLS 1.3 API GW policies, VPC link v2 -> ALB
    random  = { source = "hashicorp/random", version = "~> 3.9" } # ephemeral random_password
    archive = { source = "hashicorp/archive", version = "~> 2.8" }
  }
  backend "s3" {
    key          = "platform/terraform.tfstate"
    region       = "eu-west-3"
    use_lockfile = true # native S3 locking, no DynamoDB table
    encrypt      = true
    # bucket + kms_key_id: -backend-config (CI variables)
  }
}
