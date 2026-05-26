#!/usr/bin/env bash
# bootstrap.sh — one-time setup to get AWS infrastructure ready.
#
# What this does:
#   1. Creates the ECR repository
#   2. Creates the GitHub Actions IAM user + access keys
#   3. Builds and pushes an initial Docker image (Lambda needs one to exist)
#   4. Runs terraform init + apply to provision Lambda, IAM role, Function URL
#   5. Prints the GitHub secrets you need to set
#
# Terraform state is local — run this (and future `terraform apply`) from your machine.
#
# Run once from the repo root:
#   cp terraform/terraform.tfvars.example terraform/terraform.tfvars  # edit values first
#   cp .env.example .env                                               # for AWS creds
#   chmod +x scripts/bootstrap.sh && ./scripts/bootstrap.sh
#
# Prerequisites: aws CLI configured, Docker running, terraform installed.

set -euo pipefail

# ── Load .env (required) ─────────────────────────────────────────────────────
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ENV_FILE="${SCRIPT_DIR}/../.env"
[ -f "${ENV_FILE}" ] || { echo "❌ .env not found. Copy .env.example to .env and fill it in."; exit 1; }
set -a && source "${ENV_FILE}" && set +a

# ── Config ────────────────────────────────────────────────────────────────────
CI_USER="${APP_NAME}-ci"
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_URL="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${APP_NAME}"

echo "==> Account: ${AWS_ACCOUNT_ID}"
echo "==> Region:  ${AWS_REGION}"
echo "==> App:     ${APP_NAME}"
echo ""

# ── 1. ECR repository ────────────────────────────────────────────────────────
# ECR (Elastic Container Registry) is AWS's private Docker registry.
# Lambda container images must be pulled from ECR — you cannot point a Lambda
# at Docker Hub or any other public registry.
# ECR must exist before we can push the Docker image, and the image must exist
# before Terraform can create the Lambda function. This is a chicken-and-egg
# problem solved by a targeted Terraform apply: create just the ECR repo first,
# push the image, then run the full apply for everything else.
#
# Using Terraform (rather than aws ecr create-repository) keeps the repo tracked
# in state so it's destroyed cleanly with terraform destroy.
# terraform.tfvars must exist before we run Terraform — it sets aws_region and
# app_name. We don't auto-generate it from .env so that infra values are
# explicitly reviewed before any apply. Copy the example to get started:
#   cp terraform/terraform.tfvars.example terraform/terraform.tfvars
TFVARS="${SCRIPT_DIR}/../terraform/terraform.tfvars"
[ -f "${TFVARS}" ] || {
  echo "❌ terraform/terraform.tfvars not found."
  echo "   Copy the example and fill it in:"
  echo "   cp terraform/terraform.tfvars.example terraform/terraform.tfvars"
  exit 1
}
echo "==> Using terraform/terraform.tfvars"

echo "==> Creating ECR repository via Terraform"
cd "${SCRIPT_DIR}/../terraform"
terraform init -input=false
terraform apply -target=aws_ecr_repository.api -auto-approve
cd "${SCRIPT_DIR}/.."

# ── 2. GitHub Actions IAM user ───────────────────────────────────────────────
# Creates a dedicated IAM user for CI rather than reusing personal credentials.
#
# Access keys are created once; the secret is only visible at creation time
# (AWS will not return it again), so bootstrap prints it at the end for you
# to copy into GitHub secrets. If you lose it, delete the key and re-run.
echo "==> Creating IAM user: ${CI_USER}"

# Least-privilege policy for the GitHub Actions CI user.
# Five statements, each scoped as tightly as AWS allows:
#
#   ECRAuth       — GetAuthorizationToken is account-level; AWS does not support
#                   resource restrictions on this action, so Resource: * is
#                   required. It only produces a temporary docker login password.
#
#   ECRRepository — Push/pull actions for the one ECR repository used by this
#                   app. Scoped to the repository ARN so the CI user cannot
#                   read or write any other registry in the account.
#
#   Lambda        — Minimum actions to deploy a new container image and verify
#                   it went live. Scoped to the single Lambda function ARN.
#
#   S3Frontend    — Read/write access to the frontend S3 bucket only.
#                   The bucket name is predictable from APP_NAME so we can
#                   scope it here before Terraform runs.
#
#   CloudFront    — CreateInvalidation to bust the CDN cache after each deploy.
#                   GetDistribution to read the domain name for the job summary.
#                   Scoped to all distributions in the account (the distribution
#                   ID isn't known until after terraform apply, so we can't be
#                   more specific without a two-step bootstrap).

CI_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ECRAuth",
      "Effect": "Allow",
      "Action": ["ecr:GetAuthorizationToken"],
      "Resource": "*"
    },
    {
      "Sid": "ECRRepository",
      "Effect": "Allow",
      "Action": [
        "ecr:BatchCheckLayerAvailability",
        "ecr:GetDownloadUrlForLayer",
        "ecr:BatchGetImage",
        "ecr:InitiateLayerUpload",
        "ecr:UploadLayerPart",
        "ecr:CompleteLayerUpload",
        "ecr:PutImage"
      ],
      "Resource": "arn:aws:ecr:${AWS_REGION}:${AWS_ACCOUNT_ID}:repository/${APP_NAME}"
    },
    {
      "Sid": "Lambda",
      "Effect": "Allow",
      "Action": [
        "lambda:UpdateFunctionCode",
        "lambda:GetFunction",
        "lambda:GetFunctionUrlConfig",
        "lambda:WaitForFunctionUpdated"
      ],
      "Resource": "arn:aws:lambda:${AWS_REGION}:${AWS_ACCOUNT_ID}:function:${APP_NAME}"
    },
    {
      "Sid": "S3Frontend",
      "Effect": "Allow",
      "Action": [
        "s3:PutObject",
        "s3:DeleteObject",
        "s3:GetObject",
        "s3:ListBucket"
      ],
      "Resource": [
        "arn:aws:s3:::${APP_NAME}-frontend-${AWS_REGION}",
        "arn:aws:s3:::${APP_NAME}-frontend-${AWS_REGION}/*"
      ]
    },
    {
      "Sid": "CloudFront",
      "Effect": "Allow",
      "Action": [
        "cloudfront:CreateInvalidation",
        "cloudfront:GetDistribution"
      ],
      "Resource": "arn:aws:cloudfront::${AWS_ACCOUNT_ID}:distribution/*"
    }
  ]
}
EOF
)

if aws iam get-user --user-name "${CI_USER}" >/dev/null 2>&1; then
  echo "    (user already exists, skipping creation)"
else
  aws iam create-user --user-name "${CI_USER}"
fi

aws iam put-user-policy \
  --user-name "${CI_USER}" \
  --policy-name "${APP_NAME}-ci-policy" \
  --policy-document "${CI_POLICY}"
echo "    Policy attached."

KEY_COUNT=$(aws iam list-access-keys --user-name "${CI_USER}" \
  --query 'length(AccessKeyMetadata)' --output text)

if [ "${KEY_COUNT}" -gt 0 ]; then
  echo "    Access key already exists — skipping."
  echo "    (To rotate: aws iam delete-access-key --user-name ${CI_USER} --access-key-id <ID>)"
  CI_KEY_ID="(existing — check AWS console)"
  CI_KEY_SECRET="(existing — not retrievable)"
else
  KEY_OUTPUT=$(aws iam create-access-key --user-name "${CI_USER}")
  CI_KEY_ID=$(echo "${KEY_OUTPUT}" | python3 -c "import sys,json; print(json.load(sys.stdin)['AccessKey']['AccessKeyId'])")
  CI_KEY_SECRET=$(echo "${KEY_OUTPUT}" | python3 -c "import sys,json; print(json.load(sys.stdin)['AccessKey']['SecretAccessKey'])")
  echo "    Access key created."
fi

# ── 3. Build & push initial image ────────────────────────────────────────────
# Lambda requires an image to already exist in ECR at the time Terraform creates
# the function — it won't create a Lambda pointing at an empty registry.
#
# Two separate logins are required:
#   1. ECR Public  — to pull the Lambda Web Adapter base image during the build.
#      AWS requires the ECR Public auth call to always use us-east-1, regardless
#      of the region you are deploying to. This is an AWS constraint, not a typo.
#   2. ECR Private — to push the built image to your own registry in ${AWS_REGION}.
echo "==> Logging in to ECR Public (Lambda Web Adapter base image)"
aws ecr-public get-login-password --region us-east-1 \
  | docker login --username AWS --password-stdin public.ecr.aws

echo "==> Logging in to ECR Private (your registry in ${AWS_REGION})"
aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${ECR_URL}"

echo "==> Building and pushing Docker image"
# --provenance=false prevents Docker BuildKit from attaching attestation metadata,
# which would produce an OCI manifest index instead of a plain Docker image manifest.
# Lambda only supports the Docker manifest format — OCI indexes are rejected.
docker build --platform linux/amd64 --provenance=false -t "${ECR_URL}:latest" "${SCRIPT_DIR}/.."
docker push "${ECR_URL}:latest"
echo "    Done."

# ── 4. Terraform init + apply ────────────────────────────────────────────────
# Provisions all remaining AWS resources declared in terraform/:
#   - IAM execution role for Lambda (separate from the CI user above)
#   - Lambda function pointed at the ECR image pushed in step 3
#   - Lambda Function URL (public HTTPS endpoint, RESPONSE_STREAM mode for SSE)
#   - S3 bucket + CloudFront distribution for the frontend
# State is stored locally in terraform/terraform.tfstate — run make tf-apply
# from your machine for future infrastructure changes.
echo "==> Running terraform"
cd "${SCRIPT_DIR}/../terraform"
terraform init -input=false
terraform apply -auto-approve

API_URL=$(terraform output -raw api_url)

# ── 5. Print secrets summary ─────────────────────────────────────────────────
# Prints all values you need to add as GitHub Actions secrets.
# AWS_ACCESS_KEY_ID / AWS_SECRET_ACCESS_KEY authenticate the CI user created
# above. VITE_API_URL is the Lambda Function URL injected into the frontend
# build so it knows where to send API requests. The Vercel values are obtained
# separately from vercel.com — bootstrap cannot create those for you.
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ Bootstrap complete — add these to GitHub repo secrets:"
echo "  (Repo → Settings → Secrets and variables → Actions)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  Secrets  (Settings → Secrets and variables → Actions → Secrets):"
echo "  AWS_ACCESS_KEY_ID      = ${CI_KEY_ID}"
echo "  AWS_SECRET_ACCESS_KEY  = ${CI_KEY_SECRET}"
echo ""
echo "  Variables  (Settings → Secrets and variables → Actions → Variables):"
echo "  AWS_REGION             = ${AWS_REGION}"
echo "  ECR_REGISTRY           = ${ECR_URL}"
echo "  LAMBDA_FUNCTION        = ${APP_NAME}"
echo "  VITE_API_URL           = ${API_URL}"
echo "  FRONTEND_BUCKET        = $(terraform -chdir="${SCRIPT_DIR}/../terraform" output -raw frontend_bucket 2>/dev/null || echo "${APP_NAME}-frontend")"
echo "  CF_DISTRIBUTION_ID     = $(terraform -chdir="${SCRIPT_DIR}/../terraform" output -raw cloudfront_distribution_id 2>/dev/null || echo "(run make tf-apply first)")"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ⚠️  Save the secret key above — it cannot be retrieved again."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
