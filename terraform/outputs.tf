output "ecr_repository_url" {
  description = "ECR repository URL — used by deploy-backend.yml"
  value       = aws_ecr_repository.api.repository_url
}

output "lambda_function_name" {
  description = "Lambda function name — used by deploy-backend.yml"
  value       = aws_lambda_function.api.function_name
}

output "api_url" {
  description = "Lambda Function URL — set this as VITE_API_URL in Vercel"
  value       = aws_lambda_function_url.api.function_url
}
