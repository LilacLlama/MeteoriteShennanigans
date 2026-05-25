#!/usr/bin/env bash
# bootstrap.sh — one-time setup before Terraform can run.
#
# What this does:
#   1. Creates the S3 bucket for Terraform state
#   2. Creates the DynamoDB table for state locking
#   3. Creates the ECR repository (needed before the first image push)
#   4. Creates the GitHub Actions IAM user + access keys
#   5. Builds and pushes an initial Docker image (Lambda needs an image to exist)
#   6. Runs terraform init + apply to provision everything else
#   7. Prints all GitHub secrets you need to set
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
CI_USER="${APP_NAME}-ci"

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
if aws dynamodb describe-table --table-name "${LOCK_TABLE}" >/dev/null 2>&1; then
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
if aws ecr describe-repositories --repository-names "${APP_NAME}" >/dev/null 2>&1; then
  echo "    (already exists, skipping)"
else
  aws ecr create-repository \
    --repository-name "${APP_NAME}" \
    --region "${AWS_REGION}"
  echo "    Done."
fi

# ── 4. GitHub Actions IAM user ───────────────────────────────────────────────
echo "==> Creating IAM user: ${CI_USER}"

CI_POLICY=$(cat <<EOF
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Sid": "ECR",
      "Effect": "Allow",
      "Action": ["ecr:GetAuthorizationToken", "ecr:BatchCheckLayerAvailability",
                 "ecr:GetDownloadUrlForLayer", "ecr:BatchGetImage",
                 "ecr:InitiateLayerUpload", "ecr:UploadLayerPart",
                 "ecr:CompleteLayerUpload", "ecr:PutImage"],
      "Resource": "*"
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
      "Sid": "TerraformState",
      "Effect": "Allow",
      "Action": ["s3:GetObject", "s3:PutObject", "s3:ListBucket", "s3:DeleteObject"],
      "Resource": [
        "arn:aws:s3:::${STATE_BUCKET}",
        "arn:aws:s3:::${STATE_BUCKET}/*"
      ]
    },
    {
      "Sid": "TerraformLocks",
      "Effect": "Allow",
      "Action": ["dynamodb:GetItem", "dynamodb:PutItem", "dynamodb:DeleteItem"],
      "Resource": "arn:aws:dynamodb:${AWS_REGION}:${AWS_ACCOUNT_ID}:table/${LOCK_TABLE}"
    },
    {
      "Sid": "TerraformManage",
      "Effect": "Allow",
      "Action": ["ecr:*", "lambda:*", "iam:*", "logs:*"],
      "Resource": "*"
    }
  ]
}
EOF
)

if aws iam get-user --user-name "${CI_USER}" >/dev/null 2>&1; then
  echo "    (user already exists, skipping creation)"
else
  aws iam create-user --user-name "${CI_USER}"
  echo "    Done."
fi

# Always reconcile the policy (idempotent)
aws iam put-user-policy \
  --user-name "${CI_USER}" \
  --policy-name "${APP_NAME}-ci-policy" \
  --policy-document "${CI_POLICY}"
echo "    Policy attached."

# Create a fresh access key (skip if one already exists to avoid proliferation)
KEY_COUNT=$(aws iam list-access-keys --user-name "${CI_USER}" \
  --query 'length(AccessKeyMetadata)' --output text)

if [ "${KEY_COUNT}" -gt 0 ]; then
  echo "    Access key already exists — skipping key creation."
  echo "    (To rotate: aws iam delete-access-key + rerun this script)"
  CI_KEY_ID="(existing — check AWS console)"
  CI_KEY_SECRET="(existing — not retrievable)"
else
  KEY_OUTPUT=$(aws iam create-access-key --user-name "${CI_USER}")
  CI_KEY_ID=$(echo "${KEY_OUTPUT}" | python3 -c "import sys,json; k=json.load(sys.stdin)['AccessKey']; print(k['AccessKeyId'])")
  CI_KEY_SECRET=$(echo "${KEY_OUTPUT}" | python3 -c "import sys,json; k=json.load(sys.stdin)['AccessKey']; print(k['SecretAccessKey'])")
  echo "    Access key created."
fi

# ── 5. Build & push initial image ────────────────────────────────────────────
echo "==> Logging in to ECR"
aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${ECR_URL}"

echo "==> Building Docker image"
docker build -t "${APP_NAME}:bootstrap" .

echo "==> Pushing to ECR"
docker tag "${APP_NAME}:bootstrap" "${ECR_URL}:latest"
docker push "${ECR_URL}:latest"
echo "    Done."

# ── 6. Terraform init + apply ────────────────────────────────────────────────
echo "==> Running terraform init"
cd terraform
terraform init

echo "==> Running terraform apply"
terraform apply -auto-approve

API_URL=$(terraform output -raw api_url)

# ── 7. Print secrets summary ─────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ Bootstrap complete — add these secrets to GitHub:"
echo "  (Repo → Settings → Secrets and variables → Actions)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  AWS_ACCESS_KEY_ID      = ${CI_KEY_ID}"
echo "  AWS_SECRET_ACCESS_KEY  = ${CI_KEY_SECRET}"
echo "  VITE_API_URL           = ${API_URL}"
echo ""
echo "  Also needed for Vercel deploy:"
echo "  VERCEL_TOKEN           = (from vercel.com → Settings → Tokens)"
echo "  VERCEL_ORG_ID          = (from vercel.com → Settings)"
echo "  VERCEL_PROJECT_ID      = (from your Vercel project settings)"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ⚠️  Save the secret above — it cannot be retrieved again."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
