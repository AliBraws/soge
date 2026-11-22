output "state_bucket" { value = aws_s3_bucket.state.bucket }
output "state_kms_key_arn" { value = aws_kms_key.this["state"].arn }
output "ecr_repository_url" { value = aws_ecr_repository.api.repository_url }
output "github_variables" {
  description = "Values to set in GitHub > Settings > Secrets and variables > Actions > Variables"
  value = {
    AWS_PLAN_ROLE_ARN  = aws_iam_role.ci["plan"].arn
    AWS_PUSH_ROLE_ARN  = aws_iam_role.ci["push"].arn
    AWS_APPLY_ROLE_ARN = aws_iam_role.ci["apply"].arn
    STATE_BUCKET       = aws_s3_bucket.state.bucket
    ECR_REPOSITORY     = aws_ecr_repository.api.repository_url
  }
}
