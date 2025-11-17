set -e

ENVIRONMENT=${1:-dev}          # dev | test | prod
PROJECT_NAME=${2:-twin}

echo "🚀 Deploying ${PROJECT_NAME} to ${ENVIRONMENT}..."

# 1. Build Lambda package
cd "$(dirname "$0")/.."        # project root
echo "📦 Building Lambda package..."
(cd backend && uv run deploy.py)

# 2. Terraform workspace & apply
cd terraform
# passing extra configuration for the terraform backend to use the S3 backend for storing the state of the terraform configuration
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)
AWS_REGION=${DEFAULT_AWS_REGION:-us-east-1}
terraform init -input=false \
  -backend-config="bucket=twin-terraform-state-${AWS_ACCOUNT_ID}" \
  -backend-config="key=${ENVIRONMENT}/terraform.tfstate" \
  -backend-config="region=${AWS_REGION}" \
  -backend-config="dynamodb_table=twin-terraform-locks" \
  -backend-config="encrypt=true"

if ! terraform workspace list | grep -q "$ENVIRONMENT"; then
  terraform workspace new "$ENVIRONMENT"
else
  terraform workspace select "$ENVIRONMENT"
fi

# Get GitHub repository from environment or default
GITHUB_REPO=${GITHUB_REPOSITORY:-manuetov/digital-twin}

# Import existing resources if they exist (ignore errors if already imported)
echo "🔄 Checking for existing global resources..."
AWS_ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text)

# Try to import OIDC Provider if it exists
terraform import -var="github_repository=$GITHUB_REPO" \
  aws_iam_openid_connect_provider.github \
  "arn:aws:iam::${AWS_ACCOUNT_ID}:oidc-provider/token.actions.githubusercontent.com" 2>/dev/null || echo "  ℹ️  OIDC Provider already imported or doesn't exist"

# Try to import S3 bucket if it exists
terraform import \
  aws_s3_bucket.terraform_state \
  "twin-terraform-state-${AWS_ACCOUNT_ID}" 2>/dev/null || echo "  ℹ️  S3 bucket already imported or doesn't exist"

# Try to import DynamoDB table if it exists
terraform import \
  aws_dynamodb_table.terraform_locks \
  "twin-terraform-locks" 2>/dev/null || echo "  ℹ️  DynamoDB table already imported or doesn't exist"

# Try to import GitHub Actions IAM role if it exists
terraform import -var="github_repository=$GITHUB_REPO" \
  aws_iam_role.github_actions \
  "github-actions-twin-deploy" 2>/dev/null || echo "  ℹ️  GitHub Actions role already imported or doesn't exist"

# Use prod.tfvars for production environment
if [ "$ENVIRONMENT" = "prod" ]; then
  TF_APPLY_CMD=(terraform apply -var-file=prod.tfvars -var="project_name=$PROJECT_NAME" -var="environment=$ENVIRONMENT" -var="github_repository=$GITHUB_REPO" -auto-approve)
else
  TF_APPLY_CMD=(terraform apply -var="project_name=$PROJECT_NAME" -var="environment=$ENVIRONMENT" -var="github_repository=$GITHUB_REPO" -auto-approve)
fi

echo "🎯 Applying Terraform..."
# Try to apply, and if it fails due to lock, try to force unlock
APPLY_OUTPUT=$("${TF_APPLY_CMD[@]}" 2>&1)
APPLY_EXIT_CODE=$?

if [ $APPLY_EXIT_CODE -ne 0 ]; then
  # Check if the error is due to a state lock
  if echo "$APPLY_OUTPUT" | grep -qi "state lock\|Error acquiring the state lock"; then
    echo "⚠️  State lock detected. Attempting to force unlock..."
    # Extract lock ID from error message (format: ID: cdce4c92-d07f-d090-0e59-e3ddc1b3c976)
    LOCK_ID=$(echo "$APPLY_OUTPUT" | grep -i "ID:" | sed -n 's/.*ID:[[:space:]]*\([a-f0-9-]\+\).*/\1/p' | head -1 || echo "")
    if [ -n "$LOCK_ID" ]; then
      echo "  Found lock ID: $LOCK_ID"
      echo "  Attempting to force unlock..."
      terraform force-unlock -force "$LOCK_ID" || echo "  ⚠️  Could not unlock automatically"
      echo "  Retrying apply..."
      "${TF_APPLY_CMD[@]}"
    else
      echo "  ❌ Could not extract lock ID from error message"
      echo "  You may need to manually unlock using: terraform force-unlock <LOCK_ID>"
      exit 1
    fi
  else
    # If it's not a lock error, show the error and exit
    echo "$APPLY_OUTPUT"
    exit 1
  fi
fi

API_URL=$(terraform output -raw api_gateway_url)
FRONTEND_BUCKET=$(terraform output -raw s3_frontend_bucket)
CUSTOM_URL=$(terraform output -raw custom_domain_url 2>/dev/null || true)

# 3. Build + deploy frontend
cd ../frontend

# Create production environment file with API URL
echo "📝 Setting API URL for production..."
echo "NEXT_PUBLIC_API_URL=$API_URL" > .env.production

npm install
npm run build
aws s3 sync ./out "s3://$FRONTEND_BUCKET/" --delete
cd ..

# 4. Final messages
echo -e "\n✅ Deployment complete!"
echo "🌐 CloudFront URL : $(terraform -chdir=terraform output -raw cloudfront_url)"
if [ -n "$CUSTOM_URL" ]; then
  echo "🔗 Custom domain  : $CUSTOM_URL"
fi
echo "📡 API Gateway    : $API_URL"