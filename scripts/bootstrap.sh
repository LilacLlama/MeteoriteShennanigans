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
# ECR (Elastic Container Registry) is AWS's private Docker registry.
# Lambda container images must be pulled from ECR — you cannot point a Lambda
# at Docker Hub or any other public registry. The repository has to exist before
# Terraform runs, because the Lambda resource references it by URL.
# describe-repositories exits non-zero if the repo doesn't exist, which is
# how we detect whether to create it (idempotent on re-runs).
echo "==> Creating ECR repository: ${APP_NAME}"
if aws ecr describe-repositories --repository-names "${APP_NAME}" >/dev/null 2>&1; then
  echo "    (already exists, skipping)"
else
  aws ecr create-repository --repository-name "${APP_NAME}" --region "${AWS_REGION}"
  echo "    Done."
fi

# ── 2. GitHub Actions IAM user ───────────────────────────────────────────────
# Creates a dedicated IAM user for CI rather than reusing personal credentials.
#
# Access keys are created once; the secret is only visible at creation time
# (AWS will not return it again), so bootstrap prints it at the end for you
# to copy into GitHub secrets. If you lose it, delete the key and re-run.
echo "==> Creating IAM user: ${CI_USER}"

# Least-privilege policy for the GitHub Actions CI user.
# Three statements, each scoped as tightly as AWS allows:
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
docker build -t "${ECR_URL}:latest" "${SCRIPT_DIR}/.."
docker push "${ECR_URL}:latest"
echo "    Done."

# ── 4. Terraform init + apply ────────────────────────────────────────────────
# Provisions all remaining AWS resources declared in terraform/:
#   - IAM execution role for Lambda (separate from the CI user above)
#   - Lambda function pointed at the ECR image pushed in step 3
#   - Lambda Function URL (public HTTPS endpoint, RESPONSE_STREAM mode for SSE)
# State is stored locally in terraform/terraform.tfstate
echo "==> Running terraform"
cd "${SCRIPT_DIR}/../terraform"
terraform init
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
echo ""
echo "  Also needed for Vercel deploy:"
echo "  VERCEL_TOKEN           = (vercel.com → Settings → Tokens)"
echo "  VERCEL_ORG_ID          = (vercel.com → Settings)"
echo "  VERCEL_PROJECT_ID      = (your Vercel project settings)"
echo ""
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
echo "  ⚠️  Save the secret key above — it cannot be retrieved again."
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
