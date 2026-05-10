################################################################################
# cognito.tf
# Cognito User Pool for Phase 2 + 2.5 — Cognito path (Path 2)
#
# Purpose:
#   Provides optional verified identity layer on top of JIT demo
#   User logs in via Cognito Hosted UI → token sent to /demo-access
#   Lambda validates JWT → logs real identity alongside ephemeral JIT user
#
# Domain: amitztdemo-[account-id].auth.us-east-1.amazoncognito.com
#   Suffix uses account ID — globally unique, no variable needed
#
# Callback URL: https://webapp.amitwebsite.online
#   Cognito redirects back after auth with ?code=
#   webapp exchanges code for token client-side
#
# Cost: free tier — < 50K MAU
# No MFA, no advanced security — demo use only
################################################################################

################################################################################
# User Pool
################################################################################

resource "aws_cognito_user_pool" "main" {
  name = "zerotrust-demo-pool"

  # Self-registration enabled — anyone can create a Cognito account for Path 2
  # This is intentional for a public demo
  admin_create_user_config {
    allow_admin_create_user_only = false
  }

  # Email as username
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  username_configuration {
    case_sensitive = false
  }

  # Password policy — relaxed for demo usability
  password_policy {
    minimum_length                   = 8
    require_lowercase                = true
    require_uppercase                = false
    require_numbers                  = false
    require_symbols                  = false
    temporary_password_validity_days = 7
  }

  # Email verification
  verification_message_template {
    default_email_option = "CONFIRM_WITH_CODE"
    email_subject        = "Zero Trust Lab — verify your email"
    email_message        = "Your verification code is {####}"
  }

  # Account recovery via email
  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  # Standard email attribute
  schema {
    name                     = "email"
    attribute_data_type      = "String"
    required                 = true
    mutable                  = true
    string_attribute_constraints {
      min_length = 3
      max_length = 255
    }
  }

  tags = {
    Name    = "zerotrust-demo-pool"
    Purpose = "Cognito identity layer for JIT demo Path 2"
  }
}

################################################################################
# User Pool Domain
# amitztdemo-[account-id].auth.us-east-1.amazoncognito.com
# Account ID suffix guarantees global uniqueness
################################################################################

resource "aws_cognito_user_pool_domain" "main" {
  domain       = "amitztdemo-${local.account_id}"
  user_pool_id = aws_cognito_user_pool.main.id
}

################################################################################
# App Client
# Used by webapp to initiate Cognito Hosted UI flow and exchange auth code
################################################################################

resource "aws_cognito_user_pool_client" "webapp" {
  name         = "zerotrust-webapp-client"
  user_pool_id = aws_cognito_user_pool.main.id

  # No client secret — public client (SPA, no server-side secret handling)
  generate_secret = false

  # Auth code flow only — no implicit grant
  allowed_oauth_flows                  = ["code"]
  allowed_oauth_scopes                 = ["openid", "email", "profile"]
  allowed_oauth_flows_user_pool_client = true
  supported_identity_providers         = ["COGNITO"]

  # Callback: webapp receives ?code= and exchanges for token
  callback_urls = [local.webapp_url]
  logout_urls   = [local.webapp_url]

  # Token validity
  access_token_validity  = 1   # hours
  id_token_validity      = 1   # hours
  refresh_token_validity = 1   # days — demo, short-lived

  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }

  # Prevent user existence errors leaking in auth responses
  prevent_user_existence_errors = "ENABLED"

  # Read standard attributes
  read_attributes  = ["email", "email_verified"]
  write_attributes = ["email"]

  # Enable auth flows needed for hosted UI
  explicit_auth_flows = [
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]
}
