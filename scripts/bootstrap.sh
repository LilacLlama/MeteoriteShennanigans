#!/usr/bin/env bash
# bootstrap.sh — one-time setup before Terraform can run.
#
# What this does:
#   1. Creates the S3 bucket for Terraform state
#   2. Creates the DynamoDB table for state locking
#   3. Creates the ECR repository (needed before the first image push)
#   4. Builds and pushes an initial Docker image (Lambda needs an image to exist)
#   5. Runs terraform init + apply to provision everything else
#
# Run once from the repo root:
#   chmod +x scripts/bootstrap.sh && ./scripts/bootstrap.sh
#
# Prerequisites: aws CLI configured, Docker running, terraform installed.

set -euo pipefail

APP_NAME="meteorite-explorer"
AWS_REGION="${AWS_REGION:-us-east-1}"
STATE_BUCKET="${APP_NAME}-terraform-state"
LOCK_TABLE="${APP_NAME}-terraform-locks"

AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
ECR_URL="${AWS_ACCOUNT_ID}.dkr.ecr.${AWS_REGION}.amazonaws.com/${APP_NAME}"

echo "==> Account: ${AWS_ACCOUNT_ID}"
echo "==> Region:  ${AWS_REGION}"
echo ""

# ── 1. S3 state bucket ───────────────────────────────────────────────────────
echo "==> Creating S3 state bucket: ${STATE_BUCKET}"
if aws s3api head-bucket --bucket "${STATE_BUCKET}" 2>/dev/null; then
  echo "    (already exists, skipping)"
else
  if [ "${AWS_REGION}" = "us-east-1" ]; then
    aws s3api create-bucket \
      --bucket "${STATE_BUCKET}" \
      --region "${AWS_REGION}"
  else
    aws s3api create-bucket \
      --bucket "${STATE_BUCKET}" \
      --region "${AWS_REGION}" \
      --create-bucket-configuration LocationConstraint="${AWS_REGION}"
  fi
  aws s3api put-bucket-versioning \
    --bucket "${STATE_BUCKET}" \
    --versioning-configuration Status=Enabled
  aws s3api put-bucket-encryption \
    --bucket "${STATE_BUCKET}" \
    --server-side-encryption-configuration \
    '{"Rules":[{"ApplyServerSideEncryptionByDefault":{"SSEAlgorithm":"AES256"}}]}'
  echo "    Done."
fi

# ── 2. DynamoDB lock table ────────────────────────────────────────────────────
echo "==> Creating DynamoDB lock table: ${LOCK_TABLE}"
if aws dynamodb describe-table --table-name "${LOCK_TABLE}" 2>/dev/null; then
  echo "    (already exists, skipping)"
else
  aws dynamodb create-table \
    --table-name "${LOCK_TABLE}" \
    --attribute-definitions AttributeName=LockID,AttributeType=S \
    --key-schema AttributeName=LockID,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    --region "${AWS_REGION}"
  echo "    Waiting for table to be active..."
  aws dynamodb wait table-exists --table-name "${LOCK_TABLE}"
  echo "    Done."
fi

# ── 3. ECR repository ────────────────────────────────────────────────────────
echo "==> Creating ECR repository: ${APP_NAME}"
if aws ecr describe-repositories --repository-names "${APP_NAME}" 2>/dev/null; then
  echo "    (already exists, skipping)"
else
  aws ecr create-repository \
    --repository-name "${APP_NAME}" \
    --region "${AWS_REGION}"
  echo "    Done."
fi

# ── 4. Build & push initial image ────────────────────────────────────────────
echo "==> Logging in to ECR"
aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${ECR_URL}"

echo "==> Building Docker image"
docker build -t "${APP_NAME}:bootstrap" .

echo "==> Pushing to ECR"
docker tag "${APP_NAME}:bootstrap" "${ECR_URL}:latest"
docker push "${ECR_URL}:latest"
echo "    Done."

# ── 5. Terraform init + apply ────────────────────────────────────────────────
echo "==> Running terraform init"
cd terraform
terraform init

echo "==> Running terraform apply"
terraform apply -auto-approve

echo ""
echo "✅ Bootstrap complete!"
echo ""
echo "Outputs:"
terraform output
echo ""
echo "Next steps:"
echo "  1. Copy the 'api_url' output and set it as VITE_API_URL in Vercel"
echo "  2. Add AWS_ACCESS_KEY_ID and AWS_SECRET_ACCESS_KEY to GitHub repo secrets"
echo "  3. Push to main — GitHub Actions handles all future deploys"
