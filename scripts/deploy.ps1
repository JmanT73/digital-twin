param(
    [string]$Environment = "dev",   # dev | test | prod
    [string]$ProjectName = "twin"
)
$ErrorActionPreference = "Stop"

Write-Host "Deploying $ProjectName to $Environment ..." -ForegroundColor Green

# 1. Build Lambda package
Set-Location (Split-Path $PSScriptRoot -Parent)   # project root
Write-Host "Building Lambda package..." -ForegroundColor Yellow
Set-Location backend
try {
    uv run deploy.py
} catch {
    Write-Host "Error building Lambda package. Make sure Docker Desktop is running!" -ForegroundColor Red
    Write-Host "Error: $_" -ForegroundColor Red
    exit 1
}
Set-Location ..

# 2. Terraform workspace & apply
Set-Location terraform
# passing extra configuration for the terraform backend to use the S3 backend for storing the state of the terraform configuration
$awsAccountId = aws sts get-caller-identity --query Account --output text
$awsRegion = if ($env:DEFAULT_AWS_REGION) { $env:DEFAULT_AWS_REGION } else { "eu-north-1" }
terraform init -input=false `
  -backend-config="bucket=twin-terraform-state-$awsAccountId" `
  -backend-config="key=$Environment/terraform.tfstate" `
  -backend-config="region=$awsRegion" `
  -backend-config="dynamodb_table=twin-terraform-locks" `
  -backend-config="encrypt=true"

if (-not (terraform workspace list | Select-String $Environment)) {
    terraform workspace new $Environment
} else {
    terraform workspace select $Environment
}

if ($Environment -eq "prod") {
    terraform apply -var-file=prod.tfvars -var="project_name=$ProjectName" -var="environment=$Environment" -var="github_repository=manuetov/digital-twin" -auto-approve
} else {
    terraform apply -var="project_name=$ProjectName" -var="environment=$Environment" -var="github_repository=manuetov/digital-twin" -auto-approve
}

# Get outputs with error handling
try {
    $ApiUrl = terraform output -raw api_gateway_url 2>$null
    if (-not $ApiUrl -or $ApiUrl -match "Warning: No outputs found") {
        Write-Host "Warning: API Gateway URL not found. Infrastructure may not be fully deployed." -ForegroundColor Yellow
        $ApiUrl = ""
    }
} catch {
    Write-Host "Warning: Could not get API Gateway URL" -ForegroundColor Yellow
    $ApiUrl = ""
}

try {
    $FrontendBucket = terraform output -raw s3_frontend_bucket 2>$null
    if (-not $FrontendBucket -or $FrontendBucket -match "Warning: No outputs found") {
        Write-Host "Error: Frontend bucket not found. Cannot deploy frontend." -ForegroundColor Red
        exit 1
    }
} catch {
    Write-Host "Error: Could not get frontend bucket name" -ForegroundColor Red
    exit 1
}

try {
    $CloudfrontUrl = terraform output -raw cloudfront_url 2>$null
    if (-not $CloudfrontUrl -or $CloudfrontUrl -match "Warning: No outputs found") {
        $CloudfrontUrl = ""
    }
} catch {
    $CloudfrontUrl = ""
}

try { 
    $CustomUrl = terraform output -raw custom_domain_url 2>$null
    if ($CustomUrl -match "Warning: No outputs found") {
        $CustomUrl = ""
    }
} catch { 
    $CustomUrl = "" 
}

# 3. Build + deploy frontend
Set-Location ..
Set-Location frontend

Write-Host "Setting API URL for production build..." -ForegroundColor Yellow
"NEXT_PUBLIC_API_URL=$ApiUrl" | Out-File -FilePath ".env.production" -Encoding ascii

Write-Host "Installing frontend dependencies..." -ForegroundColor Yellow
npm install

Write-Host "Building frontend..." -ForegroundColor Yellow
npm run build

Write-Host "Uploading frontend assets to S3..." -ForegroundColor Yellow
aws s3 sync .\out "s3://$FrontendBucket/" --delete

Set-Location ..

# 4. Final messages
Write-Host ""
Write-Host "Deployment complete!" -ForegroundColor Green
Write-Host "CloudFront URL : $CloudfrontUrl"
if ($CustomUrl) {
    Write-Host "Custom domain  : $CustomUrl"
}
Write-Host "API Gateway    : $ApiUrl"
