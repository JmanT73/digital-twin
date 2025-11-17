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

# Use prod.tfvars for production environment
if [ "$ENVIRONMENT" = "prod" ]; then
  TF_APPLY_CMD=(terraform apply -var-file=prod.tfvars -var="project_name=$PROJECT_NAME" -var="environment=$ENVIRONMENT" -var="github_repository=$GITHUB_REPO" -auto-approve)
else
  TF_APPLY_CMD=(terraform apply -var="project_name=$PROJECT_NAME" -var="environment=$ENVIRONMENT" -var="github_repository=$GITHUB_REPO" -auto-approve)
fi

echo "🎯 Applying Terraform..."
"${TF_APPLY_CMD[@]}"

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