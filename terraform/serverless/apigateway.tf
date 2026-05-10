################################################################################
# apigateway.tf
# API Gateway HTTP API for Phase 2 + 2.5 serverless stack
#
# Routes:
#   POST /demo-access    — jit-provisioner  — no auth (open, rate-limited)
#   GET  /session-status — session-checker  — JWT authorizer (Okta)
#   GET  /session-count  — session-checker  — no auth (public counter)
#   OPTIONS /*           — CORS preflight   — handled by API GW natively
#
# Auth:
#   JWT authorizer uses Okta authorization server
#   Only /session-status requires a valid JWT
#   /demo-access is intentionally open — initiates the JIT flow
#
# CORS:
#   Allowed origin: https://webapp.amitwebsite.online only
#   Credentials: true (required for Okta token passthrough)
#
# Throttling:
#   Stage-level: var.api_throttle_rate rps / var.api_throttle_burst burst
#   Protects against demo abuse — not a production SLA
#
# Domain:
#   No custom domain — API GW execute-api URL is referenced by webapp CONFIG
#   post-apply output prints the URL to paste into webapp/index.html
################################################################################

################################################################################
# HTTP API
################################################################################

resource "aws_apigatewayv2_api" "main" {
  name          = "zerotrust-api"
  protocol_type = "HTTP"
  description   = "ZTNA JIT demo API — provisioner, revoker callback, session checker"

  cors_configuration {
    allow_origins     = [local.webapp_url]
    allow_methods     = ["GET", "POST", "OPTIONS"]
    allow_headers     = ["Content-Type", "Authorization", "X-Requested-With"]
    expose_headers    = []
    allow_credentials = true
    max_age           = 300
  }

  tags = {
    Name    = "zerotrust-api"
    Purpose = "JIT demo API — HTTP API Gateway"
  }
}

################################################################################
# JWT Authorizer — Okta
# Used only on /session-status
# Validates access tokens issued by Okta authorization server
################################################################################

resource "aws_apigatewayv2_authorizer" "okta_jwt" {
  api_id           = aws_apigatewayv2_api.main.id
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]
  name             = "okta-jwt-authorizer"

  jwt_configuration {
    audience = [var.okta_client_id]
    issuer   = "https://${var.okta_domain}/oauth2/default"
  }
}

################################################################################
# Lambda integrations
################################################################################

resource "aws_apigatewayv2_integration" "jit_provisioner" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.jit_provisioner.invoke_arn
  payload_format_version = "2.0"
  description            = "jit-provisioner Lambda integration"
}

resource "aws_apigatewayv2_integration" "session_checker" {
  api_id                 = aws_apigatewayv2_api.main.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.session_checker.invoke_arn
  payload_format_version = "2.0"
  description            = "session-checker Lambda integration"
}

################################################################################
# Routes
################################################################################

# POST /demo-access — open, no auth, rate-limited at stage level
resource "aws_apigatewayv2_route" "demo_access" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "POST /demo-access"
  target    = "integrations/${aws_apigatewayv2_integration.jit_provisioner.id}"

  # No authorizer — intentionally open to initiate JIT flow
  authorization_type = "NONE"
}

# GET /session-status — JWT required (Okta access token)
resource "aws_apigatewayv2_route" "session_status" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "GET /session-status"
  target    = "integrations/${aws_apigatewayv2_integration.session_checker.id}"

  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.okta_jwt.id
}

# GET /session-count — open, public counter displayed on webapp
resource "aws_apigatewayv2_route" "session_count" {
  api_id    = aws_apigatewayv2_api.main.id
  route_key = "GET /session-count"
  target    = "integrations/${aws_apigatewayv2_integration.session_checker.id}"

  authorization_type = "NONE"
}

################################################################################
# Stage — $default (auto-deploy)
################################################################################

resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.main.id
  name        = "$default"
  auto_deploy = true

  # Stage-level throttling — protects against demo abuse
  default_route_settings {
    throttling_rate_limit  = var.api_throttle_rate
    throttling_burst_limit = var.api_throttle_burst
    detailed_metrics_enabled = true
  }

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.api_gateway.arn
  }

  tags = {
    Name    = "zerotrust-api-default-stage"
    Purpose = "API Gateway default stage — auto-deploy"
  }
}

################################################################################
# CloudWatch log group — API Gateway access logs
# Retention aligned with var.log_retention_days (defined in cloudwatch.tf too)
################################################################################

resource "aws_cloudwatch_log_group" "api_gateway" {
  name              = "/aws/apigateway/zerotrust-api"
  retention_in_days = var.log_retention_days

  tags = {
    Name    = "/aws/apigateway/zerotrust-api"
    Purpose = "API Gateway access logs"
  }
}
