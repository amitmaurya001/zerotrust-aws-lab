################################################################################
# cloudflare.tf
# Cloudflare Zero Trust — IdP, Access application, Access policy
# Phase 2 + 2.5 — Serverless stack
#
# DNS RECORDS — NOT MANAGED HERE (intentional):
#   webapp.amitwebsite.online and private.amitwebsite.online CNAMEs are
#   one-time records already configured manually in Cloudflare dashboard.
#   Managing DNS in Terraform adds risk (accidental delete/modify of live records)
#   with no benefit — these records never change.
#
# EXISTING MANUAL CONFIGS — DO NOT TOUCH:
#   Identity Provider:  "Okta OIDC"            ← keep as reference/fallback
#   Access Application: (existing manual app)  ← keep as reference/fallback
#   Access Policy:      "Allow JIT Demo Users" ← keep as reference/fallback
#
# TERRAFORM-MANAGED (new, distinct names — manual configs untouched):
#   Identity Provider:  "Okta OIDC - Terraform"
#   Access Application: "Zero Trust Lab - Private Page - TF"
#   Access Policy:      "Allow JIT Demo Users - TF"
#
# NOT managed here:
#   All DNS records          → managed manually in Cloudflare dashboard
#   amitwebsite.online, www  → CloudFront, grey cloud, DNS only
#   login.amitwebsite.online → Okta custom domain, grey cloud
#   ACM validation CNAMEs    → grey cloud, NEVER orange cloud
#   Phase 3 tunnel records   → terraform/servers/ (Phase 3 only)
#
# NO tunnel in Phase 2/2.5
################################################################################

################################################################################
# Zero Trust — Identity Provider
# New Terraform-managed IdP — existing "Okta OIDC" manual config untouched
# Uses same existing Okta OIDC app (Cloudflare Zero Trust) — no new Okta app needed
# client_id + client_secret reference the same Okta app already working manually
################################################################################

resource "cloudflare_zero_trust_access_identity_provider" "okta_tf" {
  account_id = var.cloudflare_account_id
  name       = "Okta OIDC - Terraform"
  type       = "oidc"

  config {
    client_id     = var.okta_client_id
    client_secret = var.okta_client_secret
    auth_url      = "https://${var.okta_domain}/oauth2/default/v1/authorize"
    token_url     = "https://${var.okta_domain}/oauth2/default/v1/token"
    certs_url     = "https://${var.okta_domain}/oauth2/default/v1/keys"
    scopes        = ["openid", "email", "profile", "groups"]
  }
}

################################################################################
# Zero Trust — Access Application
# Protects private.amitwebsite.online
# Session: 15m (Cloudflare free plan minimum)
# Actual JIT revocation happens at 3 min — Lambda deletes the Okta user,
# which invalidates the Okta session regardless of the Cloudflare session window
################################################################################

resource "cloudflare_zero_trust_access_application" "private_tf" {
  account_id = var.cloudflare_account_id
  name       = "Zero Trust Lab - Private Page - TF"
  domain     = "${var.private_subdomain}.${var.domain}"
  type       = "self_hosted"

  session_duration           = var.cloudflare_session_duration
  auto_redirect_to_identity  = false
  http_only_cookie_attribute = true
}

################################################################################
# Zero Trust — Access Policy
# Allow users in Okta JITDemo group only
# jit-provisioner assigns the group on provision
# jit-revoker deletes the Okta user entirely on revoke (not just removes group)
################################################################################

resource "cloudflare_zero_trust_access_policy" "jitdemo_tf" {
  account_id     = var.cloudflare_account_id
  application_id = cloudflare_zero_trust_access_application.private_tf.id
  name           = "Allow JIT Demo Users - TF"
  precedence     = 2
  decision       = "allow"

  include {
    okta {
      name                 = ["JITDemo"]
      identity_provider_id = cloudflare_zero_trust_access_identity_provider.okta_tf.id
    }
  }
}
