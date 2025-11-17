# This file tells Terraform to use S3 for state storage, but doesn't specify the bucket name or other details. Those will be provided by the deployment scripts using -backend-config flags.
terraform {
  backend "s3" {
    # These values will be set by deployment scripts
    # For local development, they can be passed via -backend-config
  }
}