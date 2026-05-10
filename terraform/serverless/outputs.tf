################################################################################
# outputs.tf
# Terraform outputs for Phase 2 + 2.5 serverless stack
#
# After terraform apply run: terraform output
# Copy api_gateway_url, cognito_client_id, cognito_domain
# into webapp/index.html CONFIG section and push to GitHub
################################################################################

output "api_gateway_url" {
  description = "API Gateway invoke URL. Update webapp/index.html API_URL constant."
  value       = aws_apigatewayv2_api.main.api_endpoint
}

output "cognito_client_id" {
  description = "Cognito app client ID. Update webapp/index.html COGNITO_CLIENT_ID constant."
  value       = aws_cognito_user_pool_client.webapp.id
}

output "cognito_domain" {
  description = "Cognito hosted UI base URL. Update webapp/index.html COGNITO_DOMAIN constant."
  value       = "https://${aws_cognito_user_pool_domain.main.domain}.auth.${var.aws_region}.amazoncognito.com"
}

output "cognito_user_pool_id" {
  description = "Cognito user pool ID."
  value       = aws_cognito_user_pool.main.id
}

output "webapp_bucket_name" {
  description = "S3 bucket name for webapp static files."
  value       = aws_s3_bucket.webapp.bucket
}

output "webapp_bucket_website_endpoint" {
  description = "S3 website endpoint for webapp. Used in Cloudflare CNAME."
  value       = aws_s3_bucket_website_configuration.webapp.website_endpoint
}

output "private_bucket_name" {
  description = "S3 bucket name for private page static files."
  value       = aws_s3_bucket.private.bucket
}

output "private_bucket_website_endpoint" {
  description = "S3 website endpoint for private page. Used in Cloudflare CNAME."
  value       = aws_s3_bucket_website_configuration.private.website_endpoint
}

output "lambda_provisioner_arn" {
  description = "ARN of jit-provisioner Lambda function."
  value       = aws_lambda_function.jit_provisioner.arn
}

output "lambda_revoker_arn" {
  description = "ARN of jit-revoker Lambda function."
  value       = aws_lambda_function.jit_revoker.arn
}

output "lambda_checker_arn" {
  description = "ARN of session-checker Lambda function."
  value       = aws_lambda_function.session_checker.arn
}

output "sns_topic_arn" {
  description = "SNS topic ARN for CloudWatch alarm notifications."
  value       = aws_sns_topic.alerts.arn
}

output "webapp_url" {
  description = "Public URL for webapp landing page."
  value       = local.webapp_url
}

output "private_url" {
  description = "Protected URL for private page."
  value       = local.private_url
}

output "cloudflare_idp_id" {
  description = "Cloudflare Access Identity Provider ID for Okta OIDC - Terraform."
  value       = cloudflare_access_identity_provider.okta.id
}

output "scheduler_role_arn" {
  description = "EventBridge Scheduler role ARN — used by jit-provisioner Lambda."
  value       = aws_iam_role.scheduler.arn
}

output "deploy_instructions" {
  description = "Post-deploy instructions for updating webapp HTML."
  value       = <<-EOT
    ============================================================
    POST-DEPLOY STEPS
    ============================================================
    1. Update webapp/index.html CONFIG section:
       API_URL           = '${aws_apigatewayv2_api.main.api_endpoint}'
       COGNITO_CLIENT_ID = '${aws_cognito_user_pool_client.webapp.id}'
       COGNITO_DOMAIN    = 'https://${aws_cognito_user_pool_domain.main.domain}.auth.${var.aws_region}.amazoncognito.com'

    2. git add webapp/index.html
       git commit -m "chore: update API config post-deploy"
       git push
       GitHub Actions syncs updated HTML to S3 automatically

    3. Test Path 1 (anonymous): ${local.webapp_url}
    4. Test Path 2 (Cognito):   ${local.webapp_url}
    5. Verify private page:     ${local.private_url}
    ============================================================
  EOT
}
