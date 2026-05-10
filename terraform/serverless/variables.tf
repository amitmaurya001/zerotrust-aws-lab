################################################################################
# variables.tf
# All input variables for Phase 2 + 2.5 serverless stack
#
# MIGRATION NOTE:
#   Changing var.domain is the only required change for a new domain
#   All resource names, URLs, and ARNs derive from this one variable
#   Sensitive values come from GitHub Secrets — never hardcoded here
#
# GITHUB SECRETS REQUIRED (Environment: production):
#   ALERT_EMAIL             → var.alert_email
#   AWS_ROLE_ARN_SERVERLESS → used in workflow, not here
#   CLOUDFLARE_ACCOUNT_ID   → var.cloudflare_account_id
#   CLOUDFLARE_API_TOKEN    → var.cloudflare_api_token
#   CLOUDFLARE_ZONE_ID      → var.cloudflare_zone_id
#   OKTA_CLIENT_ID          → var.okta_client_id
#   OKTA_CLIENT_SECRET      → var.okta_client_secret
#   OKTA_DOMAIN             → var.okta_domain
#   TF_STATE_BUCKET         → passed via -backend-config in workflow
################################################################################

################################################################################
# AWS
################################################################################

variable "aws_region" {
  description = "AWS region for all resources. Change for regional migration."
  type        = string
  default     = "us-east-1"
}

################################################################################
# Domain + subdomains
################################################################################

variable "domain" {
  description = "Root domain. All subdomains and resource names derive from this."
  type        = string
  default     = "amitwebsite.online"
}

variable "webapp_subdomain" {
  description = "Subdomain for public JIT demo landing page."
  type        = string
  default     = "webapp"
}

variable "private_subdomain" {
  description = "Subdomain for Cloudflare Access protected resource."
  type        = string
  default     = "private"
}

################################################################################
# Project metadata
################################################################################

variable "project" {
  description = "Project name for tagging and resource naming."
  type        = string
  default     = "zerotrust-aws-lab"
}

variable "environment" {
  description = "Deployment environment for tagging."
  type        = string
  default     = "prod"
}

################################################################################
# Cloudflare
# All three injected from GitHub Secrets — no hardcoded defaults
# Migration: update secrets only, no file changes needed
################################################################################

variable "cloudflare_api_token" {
  description = "Cloudflare API token. Injected from GitHub Secret CLOUDFLARE_API_TOKEN."
  type        = string
  sensitive   = true
}

variable "cloudflare_account_id" {
  description = "Cloudflare account ID. Injected from GitHub Secret CLOUDFLARE_ACCOUNT_ID."
  type        = string
  sensitive   = true
}

variable "cloudflare_zone_id" {
  description = "Cloudflare zone ID. Injected from GitHub Secret CLOUDFLARE_ZONE_ID."
  type        = string
  sensitive   = true
}

################################################################################
# Okta
# All three injected from GitHub Secrets — no hardcoded defaults
################################################################################

variable "okta_domain" {
  description = "Okta tenant domain. Injected from GitHub Secret OKTA_DOMAIN."
  type        = string
  sensitive   = true
}

variable "okta_client_id" {
  description = "Okta OIDC application client ID. Injected from GitHub Secret OKTA_CLIENT_ID."
  type        = string
  sensitive   = true
}

variable "okta_client_secret" {
  description = "Okta OIDC application client secret. Injected from GitHub Secret OKTA_CLIENT_SECRET."
  type        = string
  sensitive   = true
}

################################################################################
# JIT session configuration
################################################################################

variable "jit_session_duration_seconds" {
  description = "Duration before EventBridge fires jit-revoker and deletes Okta user."
  type        = number
  default     = 180
}

variable "cloudflare_session_duration" {
  description = <<-EOT
    Cloudflare Access session duration.
    NOTE: Free plan minimum is 15m. Actual JIT revocation happens at 3 min via
    Lambda/EventBridge deleting the Okta user — independent of this value.
  EOT
  type        = string
  default     = "15m"
}

################################################################################
# Lambda
################################################################################

variable "lambda_runtime" {
  description = "Lambda Python runtime version."
  type        = string
  default     = "python3.12"
}

variable "lambda_memory_mb" {
  description = "Lambda memory allocation in MB."
  type        = number
  default     = 256
}

variable "lambda_timeout_provisioner" {
  description = "Timeout for jit-provisioner Lambda in seconds."
  type        = number
  default     = 30
}

variable "lambda_timeout_revoker" {
  description = "Timeout for jit-revoker Lambda in seconds."
  type        = number
  default     = 60
}

variable "lambda_timeout_checker" {
  description = "Timeout for session-checker Lambda in seconds."
  type        = number
  default     = 10
}

################################################################################
# Cognito
################################################################################

variable "cognito_domain_prefix" {
  description = "Cognito hosted UI domain prefix. Must be globally unique."
  type        = string
  default     = "zerotrustdemo-amit"
}

################################################################################
# CloudWatch + alerting
################################################################################

variable "log_retention_days" {
  description = "CloudWatch log group retention in days."
  type        = number
  default     = 30
}

variable "alert_email" {
  description = "Email for CloudWatch alarm SNS notifications. Injected from GitHub Secret ALERT_EMAIL."
  type        = string
}

################################################################################
# API Gateway throttling
################################################################################

variable "api_throttle_rate" {
  description = "API Gateway throttle rate limit (requests per second)."
  type        = number
  default     = 10
}

variable "api_throttle_burst" {
  description = "API Gateway throttle burst limit."
  type        = number
  default     = 5
}
