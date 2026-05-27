# ── CI IAM User ──────────────────────────────────────────────────────────────
# Least-privilege IAM user for GitHub Actions CI/CD.
#
# Access keys are NOT managed here — Terraform would store the secret in state.
# Instead, bootstrap.sh creates the key once with aws iam create-access-key
# and prints it for you to save as a GitHub secret.

data "aws_caller_identity" "current" {}

resource "aws_iam_user" "ci" {
  name          = "${var.app_name}-ci"
  force_destroy = true # deletes access keys automatically on destroy
}

resource "aws_iam_user_policy" "ci" {
  name = "${var.app_name}-ci-policy"
  user = aws_iam_user.ci.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      # ECRAuth — GetAuthorizationToken calls are account-level; AWS does not
      # support resource restrictions on these actions so Resource: * is required.
      # ecr-public:GetAuthorizationToken + sts:GetServiceBearerToken are needed
      # to pull the Lambda Web Adapter base image from ECR Public during docker build.
      {
        Sid    = "ECRAuth"
        Effect = "Allow"
        Action = [
          "ecr:GetAuthorizationToken",
          "ecr-public:GetAuthorizationToken",
          "sts:GetServiceBearerToken",
        ]
        Resource = "*"
      },

      # ECRRepository — push/pull scoped to this app's repository only.
      {
        Sid    = "ECRRepository"
        Effect = "Allow"
        Action = [
          "ecr:BatchCheckLayerAvailability",
          "ecr:GetDownloadUrlForLayer",
          "ecr:BatchGetImage",
          "ecr:InitiateLayerUpload",
          "ecr:UploadLayerPart",
          "ecr:CompleteLayerUpload",
          "ecr:PutImage",
        ]
        Resource = aws_ecr_repository.api.arn
      },

      # Lambda — minimum actions to deploy a new image and confirm it went live.
      # GetFunctionConfiguration is what `aws lambda wait function-updated` polls
      # internally — it is a separate IAM action from GetFunction.
      # WaitForFunctionUpdated is not a real IAM action; removed.
      {
        Sid    = "Lambda"
        Effect = "Allow"
        Action = [
          "lambda:UpdateFunctionCode",
          "lambda:GetFunction",
          "lambda:GetFunctionConfiguration",
          "lambda:GetFunctionUrlConfig",
        ]
        Resource = aws_lambda_function.api.arn
      },

      # S3Frontend — read/write the frontend bucket only.
      {
        Sid    = "S3Frontend"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:DeleteObject",
          "s3:GetObject",
          "s3:ListBucket",
        ]
        Resource = [
          aws_s3_bucket.frontend.arn,
          "${aws_s3_bucket.frontend.arn}/*",
        ]
      },

      # CloudFront — invalidate CDN cache after deploy + read domain for summary.
      # Scoped to all distributions: the ID isn't known until after terraform
      # apply, so we can't narrow further without a two-pass bootstrap.
      {
        Sid    = "CloudFront"
        Effect = "Allow"
        Action = [
          "cloudfront:CreateInvalidation",
          "cloudfront:GetDistribution",
        ]
        Resource = "arn:aws:cloudfront::${data.aws_caller_identity.current.account_id}:distribution/*"
      },
    ]
  })
}
