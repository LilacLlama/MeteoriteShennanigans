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
#   cp .env.example .env   # edit values first
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
echo "==> Creating ECR repository: ${APP_NAME}"
if aws ecr describe-repositories --repository-names "${APP_NAME}" >/dev/null 2>&1; then
  echo "    (already exists, skipping)"
else
  aws ecr create-repository --repository-name "${APP_NAME}" --region "${AWS_REGION}"
  echo "    Done."
fi

# ── 2. GitHub Actions IAM user ───────────────────────────────────────────────
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
echo "==> Logging in to ECR"
aws ecr get-login-password --region "${AWS_REGION}" \
  | docker login --username AWS --password-stdin "${ECR_URL}"

echo "==> Building and pushing Docker image"
docker build -t "${ECR_URL}:latest" "${SCRIPT_DIR}/.."
docker push "${ECR_URL}:latest"
echo "    Done."

# ── 4. Terraform init + apply ────────────────────────────────────────────────
echo "==> Running terraform"
cd "${SCRIPT_DIR}/../terraform"
terraform init
terraform apply -auto-approve

API_URL=$(terraform output -raw api_url)

# ── 5. Print secrets summary ─────────────────────────────────────────────────
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ✅ Bootstrap complete — add these to GitHub repo secrets:"
echo "  (Repo → Settings → Secrets and variables → Actions)"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo ""
echo "  AWS_ACCESS_KEY_ID      = ${CI_KEY_ID}"
echo "  AWS_SECRET_ACCESS_KEY  = ${CI_KEY_SECRET}"
echo "  VITE_API_URL           = ${API_URL}"
echo ""
echo "  Also needed for Vercel deploy:"
echo "  VERCEL_TOKEN           = (vercel.com → Settings → Tokens)"
echo "  VERCEL_ORG_ID          = (vercel.com → Settings)"
echo "  VERCEL_PROJECT_ID      = (your Vercel project settings)"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ⚠️  Save the secret key above — it cannot be retrieved again."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
