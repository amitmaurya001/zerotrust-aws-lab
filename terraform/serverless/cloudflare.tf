################################################################################
# cloudflare.tf
# Cloudflare Zero Trust - IdP, Access application, Access policy
# Phase 2 + 2.5 - Serverless stack
#
# DNS RECORDS - NOT MANAGED HERE (intentional):
#   webapp and private CNAMEs managed manually in Cloudflare dashboard.
#
# EXISTING MANUAL CONFIGS - DO NOT TOUCH:
#   Identity Provider:  "Okta OIDC"             keep as fallback
#   Access Policy:      "Allow JITDemo Users"    working manual policy - keep
#
# TERRAFORM-MANAGED:
#   Identity Provider:  "Okta OIDC - Terraform"
#   Access Application: "Zero Trust Lab - Private Page - TF"
#   Access Policy:      "Allow JIT Demo Users - TF"
#
# KEY DECISIONS:
#   support_groups = true   - required for groups claim to reach Cloudflare
#   http_only_cookie = false - required so private.html JS can read CF_Authorization
#   auto_redirect = true    - skip IdP selection screen, go straight to Okta
#   policy uses oidc block  - correct for OIDC groups claim (not okta native groups)
################################################################################

################################################################################
# Zero Trust - Identity Provider
################################################################################

resource "cloudflare_zero_trust_access_identity_provider" "okta_tf" {
  account_id = var.cloudflare_account_id
  name       = "Okta OIDC - Terraform"
  type       = "oidc"

  config {
    client_id      = var.okta_client_id
    client_secret  = var.okta_client_secret
    auth_url       = "https://${var.okta_domain}/oauth2/default/v1/authorize"
    token_url      = "https://${var.okta_domain}/oauth2/default/v1/token"
    certs_url      = "https://${var.okta_domain}/oauth2/default/v1/keys"
    scopes         = ["openid", "email", "profile", "groups"]
    support_groups = true
  }
}

################################################################################
# Zero Trust - Access Application
# http_only_cookie_attribute = false - JS in private.html reads CF_Authorization
# auto_redirect_to_identity = true - skip login screen, go straight to Okta
################################################################################

resource "cloudflare_zero_trust_access_application" "private_tf" {
  account_id = var.cloudflare_account_id
  name       = "Zero Trust Lab - Private Page - TF"
  domain     = "${var.private_subdomain}.${var.domain}"
  type       = "self_hosted"

  session_duration           = var.cloudflare_session_duration
  auto_redirect_to_identity  = true
  http_only_cookie_attribute = false
}

################################################################################
# Zero Trust - Access Policy
# Uses oidc block - correct for OIDC groups claim
# identity_provider_id ties this to the TF-managed IdP only
################################################################################

resource "cloudflare_zero_trust_access_policy" "jitdemo_tf" {
  account_id     = var.cloudflare_account_id
  application_id = cloudflare_zero_trust_access_application.private_tf.id
  name           = "Allow JIT Demo Users - TF"
  precedence     = 2
  decision       = "allow"

  include {
    oidc {
      identity_provider_id = cloudflare_zero_trust_access_identity_provider.okta_tf.id
      claim_name           = "groups"
      claim_value          = "JITDemo"
    }
  }
}
