variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-east-1"
}

variable "app_name" {
  description = "Application name — used as a prefix for all resources"
  type        = string
  default     = "meteorite-explorer"
}

variable "lambda_memory_mb" {
  description = "Lambda memory in MB (DuckDB needs headroom for 45k-row dataset)"
  type        = number
  default     = 512
}

variable "lambda_timeout_s" {
  description = "Lambda timeout in seconds"
  type        = number
  default     = 30
}

variable "bedrock_model_id" {
  description = "Bedrock cross-region inference profile ID for Claude"
  type        = string
  default     = "us.anthropic.claude-sonnet-4-5-20250514-v1:0"
}
