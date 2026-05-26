terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  # Local state — run terraform apply from your machine.
  # Upgrade to S3 backend or Terraform Cloud when CI or multiple people need to apply.
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = {
      Project   = var.app_name
      ManagedBy = "terraform"
    }
  }
}
