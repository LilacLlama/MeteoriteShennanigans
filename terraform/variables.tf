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
  description = "Lambda memory in MB. 512 has headroom; the prebuilt warehouse is ~2 MB and queries are small, so 256 likely also works."
  type        = number
  default     = 512
}

variable "lambda_timeout_s" {
  description = "Lambda timeout in seconds"
  type        = number
  default     = 30
}
