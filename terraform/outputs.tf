# All Terraform outputs consumed by bootstrap.sh + deploy-backend.yml +
# deploy-frontend.yml. Resources are defined across ecr.tf / lambda.tf /
# frontend.tf; outputs are collected here so there's one place to look.

# ── Backend ─────────────────────────────────────────────────────────────────

output "ecr_repository_url" {
  description = "ECR repository URL — used by deploy-backend.yml"
  value       = aws_ecr_repository.api.repository_url
}

output "lambda_function_name" {
  description = "Lambda function name — used by deploy-backend.yml"
  value       = aws_lambda_function.api.function_name
}

output "api_url" {
  description = "Lambda Function URL — set this as VITE_API_URL for the frontend build"
  value       = aws_lambda_function_url.api.function_url
}

# ── Frontend ────────────────────────────────────────────────────────────────

output "frontend_bucket" {
  description = "S3 bucket name — used by deploy-frontend.yml for aws s3 sync"
  value       = aws_s3_bucket.frontend.id
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID — used by deploy-frontend.yml for cache invalidation"
  value       = aws_cloudfront_distribution.frontend.id
}

output "frontend_url" {
  description = "Public URL of the frontend"
  value       = "https://${aws_cloudfront_distribution.frontend.domain_name}"
}
