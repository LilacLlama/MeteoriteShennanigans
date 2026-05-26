#!/usr/bin/env bash
# bootstrap.sh — one-time setup to get AWS infrastructure ready.
#
# What this does:
#   1. Creates the ECR repository (targeted terraform apply)
#   2. Builds and pushes an initial Docker image (Lambda needs one to exist)
#   3. Runs full terraform apply — Lambda, IAM roles, CI user + policy, S3, CloudFront
#   4. Creates the GitHub Actions IAM access key (CLI only — secret not stored in state)
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

# ── 2. Build & push initial image ────────────────────────────────────────────
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

# ── 3. Terraform init + apply ────────────────────────────────────────────────
# Provisions all AWS resources declared in terraform/:
#   - CI IAM user + least-privilege policy (terraform/iam_ci.tf)
#   - IAM execution role for Lambda
#   - Lambda function pointed at the ECR image pushed in step 2
#   - Lambda Function URL (public HTTPS endpoint, RESPONSE_STREAM mode for SSE)
#   - S3 bucket + CloudFront distribution for the frontend
# State is stored locally in terraform/terraform.tfstate — run make tf-apply
# from your machine for future infrastructure changes.
echo "==> Running terraform"
cd "${SCRIPT_DIR}/../terraform"
terraform init -input=false
terraform apply -auto-approve

API_URL=$(terraform output -raw api_url)

# ── 4. GitHub Actions access key ─────────────────────────────────────────────
# The CI IAM user is created by Terraform above. We create its access key here
# via CLI because Terraform would store the secret in state (plaintext).
# The secret is only shown once — save it to GitHub secrets immediately.
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
