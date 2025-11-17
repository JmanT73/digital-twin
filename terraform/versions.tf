terraform {
  required_version = ">= 1.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 6.0"
    }
  }
}

provider "aws" {
  region = "eu-north-1"
  # Uses AWS CLI configuration (aws configure)
}

provider "aws" {
  alias  = "us_east_1"
  region = "us-east-1"
}