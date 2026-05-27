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

# Bedrock invoke policy lived here previously for the Claude agent — removed
# along with the agent itself (see DEVLOG 2026-05-25). Reintroduce alongside
# the agent code if/when it comes back.

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

  # No environment variables today. AWS_REGION is reserved — Lambda injects
  # it automatically; app code reads os.environ["AWS_REGION"] without us
  # setting it here. Add an environment {} block if/when the agent returns
  # (it needed BEDROCK_MODEL_ID).

  lifecycle {
    ignore_changes = [image_uri]
  }

  depends_on = [aws_iam_role_policy_attachment.lambda_basic]
}

# ── Lambda permission: allow public invocation via Function URL ───────────────
# authorization_type = "NONE" on the Function URL makes it publicly addressable,
# but Lambda still requires an explicit resource-based policy statement allowing
# invocation. Without this, requests get a 403 Forbidden even on a public URL.
#
# As of October 2025, public Function URLs require BOTH lambda:InvokeFunctionUrl
# AND lambda:InvokeFunction in the resource policy — granting only the first
# returns 403 with x-amzn-ErrorType: AccessDeniedException.
# https://docs.aws.amazon.com/lambda/latest/dg/urls-auth.html#urls-auth-none

resource "aws_lambda_permission" "function_url_public" {
  statement_id           = "FunctionURLAllowPublicAccess"
  action                 = "lambda:InvokeFunctionUrl"
  function_name          = aws_lambda_function.api.function_name
  principal              = "*"
  function_url_auth_type = "NONE"
}

# Required since Oct 2025: function URLs need InvokeFunction in addition to
# InvokeFunctionUrl. AWS recommends adding the InvokedViaFunctionUrl condition
# (restricts to URL-only invocation), but the Terraform AWS provider doesn't
# support that condition key on aws_lambda_permission yet. Omitting it is safe
# for a public API — direct invocation still requires valid AWS credentials.
resource "aws_lambda_permission" "function_url_invoke" {
  statement_id  = "FunctionURLInvokeAllowPublicAccess"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.api.function_name
  principal     = "*"
}

# ── Function URL (streaming SSE support) ────────────────────────────────────
#
# No cors {} block here — FastAPI's CORSMiddleware (backend/main.py) owns CORS.
# Enabling both causes the `access-control-allow-origin` header to appear twice
# in the response, which Chrome treats as a duplicate/concatenated value and
# rejects with a CORS error, breaking all API calls in the browser.

resource "aws_lambda_function_url" "api" {
  function_name      = aws_lambda_function.api.function_name
  authorization_type = "NONE"
  invoke_mode        = "RESPONSE_STREAM"
}
