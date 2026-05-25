# ── IAM Role ────────────────────────────────────────────────────────────────

resource "aws_iam_role" "lambda" {
  name = "${var.app_name}-lambda"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# Basic execution (CloudWatch Logs)
resource "aws_iam_role_policy_attachment" "lambda_basic" {
  role       = aws_iam_role.lambda.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

# Bedrock — invoke Claude models
resource "aws_iam_role_policy" "bedrock" {
  name = "${var.app_name}-bedrock"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect = "Allow"
      Action = [
        "bedrock:InvokeModel",
        "bedrock:InvokeModelWithResponseStream",
      ]
      # Scope to Anthropic models only
      Resource = "arn:aws:bedrock:${var.aws_region}::foundation-model/anthropic.*"
    }]
  })
}

# ── Lambda Function ──────────────────────────────────────────────────────────

resource "aws_lambda_function" "api" {
  function_name = var.app_name
  role          = aws_iam_role.lambda.arn
  package_type  = "Image"

  # bootstrap.sh pushes the first image before terraform apply runs.
  # Subsequent app deploys update image_uri via AWS CLI in deploy-backend.yml;
  # Terraform ignores those changes so it doesn't revert them.
  image_uri = "${aws_ecr_repository.api.repository_url}:latest"

  memory_size = var.lambda_memory_mb
  timeout     = var.lambda_timeout_s

  environment {
    variables = {
      AWS_REGION       = var.aws_region
      BEDROCK_MODEL_ID = var.bedrock_model_id
    }
  }

  lifecycle {
    ignore_changes = [image_uri]
  }

  depends_on = [aws_iam_role_policy_attachment.lambda_basic]
}

# ── Function URL (streaming SSE support) ────────────────────────────────────

resource "aws_lambda_function_url" "api" {
  function_name      = aws_lambda_function.api.function_name
  authorization_type = "NONE"
  invoke_mode        = "RESPONSE_STREAM"

  cors {
    allow_origins = ["*"]
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_headers = ["Content-Type"]
    max_age       = 86400
  }
}
