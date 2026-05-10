################################################################################
# backend.tf
# Terraform backend + provider configuration
# Phase 2 + 2.5 — Serverless stack
#
# PRE-REQUISITES (create manually before terraform init):
#   S3 bucket:  name stored in GitHub Secret TF_STATE_BUCKET
#               versioning ON, encryption ON, public access OFF
#   TF version: >= 1.4.8
#   S3 locking: use_lockfile = true (no DynamoDB needed)
#
# MIGRATION TO NEW AWS ACCOUNT:
#   1. Create new S3 state bucket in new account
#   2. Update GitHub Secret TF_STATE_BUCKET with new bucket name
#   3. Update GitHub Secret AWS_ROLE_ARN_SERVERLESS with new role ARN
#   4. Update all other GitHub Secrets if credentials changed
#   5. terraform init -reconfigure  (workflow handles this automatically)
#   No file changes needed — all config via GitHub Secrets
#
# PARTIAL BACKEND CONFIG:/Users/amit/Downloads/zerotrustproject/zt/files(1)/cloudflare.tf
#   bucket is intentionally omitted here — injected at runtime by GitHub Actions:
#   terraform init -backend-config="bucket=${{ secrets.TF_STATE_BUCKET }}"
#   This allows account migration with zero file changes.
################################################################################

terraform {
  required_version = ">= 1.4.7"

  backend "s3" {
    # bucket        — injected via -backend-config="bucket=..." in GitHub Actions
    #                 GitHub Secret: TF_STATE_BUCKET
    key          = "zerotrust/serverless/terraform.tfstate"
    region       = "us-east-1"
    encrypt      = true
    use_lockfile = true
  }

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
    cloudflare = {
      source  = "cloudflare/cloudflare"
      version = "~> 4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = "~> 3.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = "~> 2.0"
    }
  }
}

provider "aws" {
  region = var.aws_region

  default_tags {
    tags = local.common_tags
  }
}

provider "cloudflare" {
  api_token = var.cloudflare_api_token
}

data "aws_caller_identity" "current" {}
data "aws_region" "current" {}

data "cloudflare_zone" "main" {
  name = var.domain
}

locals {
  account_id = data.aws_caller_identity.current.account_id
  region     = data.aws_region.current.name

  common_tags = {
    Project     = var.project
    Environment = var.environment
    ManagedBy   = "terraform"
    Phase       = "serverless"
    Owner       = "amit-maurya"
    Repo        = "github.com/amitmaurya001/zerotrust-aws-lab"
  }

  webapp_bucket_name  = "${var.webapp_subdomain}.${var.domain}"
  private_bucket_name = "${var.private_subdomain}.${var.domain}"
  webapp_url          = "https://${var.webapp_subdomain}.${var.domain}"
  private_url         = "https://${var.private_subdomain}.${var.domain}"

  fn_provisioner = "jit-provisioner"
  fn_revoker     = "jit-revoker"
  fn_checker     = "session-checker"

  ssm_prefix        = "/zerotrust"
  ssm_okta_domain   = "/zerotrust/okta/domain"
  ssm_okta_token    = "/zerotrust/okta/api-token"
  ssm_okta_group_id = "/zerotrust/okta/group-id"
}
