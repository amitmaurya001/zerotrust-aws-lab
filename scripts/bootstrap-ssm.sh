#!/usr/bin/env bash
################################################################################
# bootstrap-ssm.sh
# Populates all /zerotrust/ SSM parameters required before terraform apply
#
# Run this once per AWS account (new account or first setup):
#   chmod +x scripts/bootstrap-ssm.sh
#   ./scripts/bootstrap-ssm.sh
#
# Prerequisites:
#   — AWS CLI configured with sufficient permissions (or run as the deploy role)
#   — AWS region set (defaults to us-east-1)
#   — Okta API token from: Okta Admin → Security → API → Tokens → Create Token
#   — Okta JITDemo group ID from: Okta Admin → Directory → Groups → JITDemo → copy ID from URL
#
# What this script creates:
#   /zerotrust/okta/domain          String       Okta tenant domain
#   /zerotrust/okta/api-token       SecureString Okta API token (SSWS ...)
#   /zerotrust/okta/group-id        String       JITDemo group ID
#   /zerotrust/cloudflare/zone-id   String       Cloudflare zone ID
#   /zerotrust/cloudflare/account-id String      Cloudflare account ID
#
# Phase 3 parameters (skipped if Phase 3 not ready):
#   /zerotrust/okta/group-id-devteam
#   /zerotrust/okta/group-id-finance
#   /zerotrust/okta/group-id-dbadmins
#   /zerotrust/okta/group-id-readonly
#   /zerotrust/okta/group-id-admin
#   /zerotrust/cloudflare/tunnel-id
#
# MIGRATION: Re-run this script in the new account. Okta and Cloudflare values
# are unchanged — same tenant, same API token, same group IDs.
################################################################################

set -euo pipefail

# ── Config ────────────────────────────────────────────────────────────────────

REGION="${AWS_REGION:-us-east-1}"
PREFIX="/zerotrust"

# ── Colours ───────────────────────────────────────────────────────────────────

RED='\033[0;31m'
GREEN='\033[0;32m'
CYAN='\033[0;36m'
YELLOW='\033[1;33m'
BOLD='\033[1m'
RESET='\033[0m'

# ── Helpers ───────────────────────────────────────────────────────────────────

info()    { echo -e "${CYAN}[INFO]${RESET} $*"; }
success() { echo -e "${GREEN}[OK]${RESET}   $*"; }
warn()    { echo -e "${YELLOW}[WARN]${RESET} $*"; }
error()   { echo -e "${RED}[ERROR]${RESET} $*"; exit 1; }

put_param() {
  local name="$1"
  local value="$2"
  local type="${3:-String}"
  local desc="${4:-}"

  aws ssm put-parameter \
    --region "$REGION" \
    --name "$name" \
    --value "$value" \
    --type "$type" \
    --description "$desc" \
    --overwrite \
    --output text > /dev/null

  success "Set $name"
}

prompt_required() {
  local var_name="$1"
  local prompt_text="$2"
  local value=""
  while [[ -z "$value" ]]; do
    read -rsp "${prompt_text}: " value
    echo
    if [[ -z "$value" ]]; then
      warn "Value cannot be empty. Try again."
    fi
  done
  echo "$value"
}

prompt_optional() {
  local prompt_text="$1"
  local default="${2:-}"
  local value=""
  read -rsp "${prompt_text} [${default}]: " value
  echo
  echo "${value:-$default}"
}

# ── Pre-flight checks ─────────────────────────────────────────────────────────

echo
echo -e "${BOLD}═══════════════════════════════════════════════════════════${RESET}"
echo -e "${BOLD}  Zero Trust Lab — SSM Bootstrap${RESET}"
echo -e "${BOLD}  Region: ${CYAN}${REGION}${RESET}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════${RESET}"
echo

# Check AWS CLI available
command -v aws &>/dev/null || error "AWS CLI not found. Install it first."

# Check AWS credentials work
info "Verifying AWS credentials..."
ACCOUNT_ID=$(aws sts get-caller-identity --query Account --output text --region "$REGION" 2>/dev/null) \
  || error "AWS credentials not configured or insufficient permissions."
success "Connected to AWS account: ${ACCOUNT_ID}"
echo

# ── Collect values ────────────────────────────────────────────────────────────

echo -e "${BOLD}Okta Configuration${RESET}"
echo -e "  Tenant: integrator-6290225.okta.com"
echo -e "  Admin:  https://integrator-6290225-admin.okta.com"
echo

OKTA_DOMAIN=$(prompt_optional "  Okta domain (press enter for default)" "integrator-6290225.okta.com")

echo
echo -e "  API Token: Okta Admin → Security → API → Tokens → zerotrust-lambda"
OKTA_TOKEN=$(prompt_required "  Okta API token (SSWS ...)" "  Okta API token")

echo
echo -e "  Group ID: Okta Admin → Directory → Groups → JITDemo → copy ID from URL"
OKTA_GROUP_ID=$(prompt_required "  JITDemo group ID" "  JITDemo group ID")

echo
echo -e "${BOLD}Cloudflare Configuration${RESET}"
echo -e "  Dashboard: https://dash.cloudflare.com"
echo
CLOUDFLARE_ZONE_ID=$(prompt_required "  Cloudflare zone ID (amitwebsite.online)" "  Zone ID")
CLOUDFLARE_ACCOUNT_ID=$(prompt_required "  Cloudflare account ID" "  Account ID")

echo
echo -e "${BOLD}Phase 3 Okta Groups${RESET} ${YELLOW}(optional — skip if Phase 3 not ready)${RESET}"
echo -e "  Press Enter to skip any Phase 3 parameter"
echo
read -rsp "  DevTeam group ID (or enter to skip): " GID_DEVTEAM; echo
read -rsp "  FinanceTeam group ID (or enter to skip): " GID_FINANCE; echo
read -rsp "  DBAdmins group ID (or enter to skip): " GID_DBADMINS; echo
read -rsp "  ReadOnly group ID (or enter to skip): " GID_READONLY; echo
read -rsp "  AdminTeam group ID (or enter to skip): " GID_ADMIN; echo

echo
echo -e "${BOLD}Phase 3 Cloudflare Tunnel${RESET} ${YELLOW}(optional)${RESET}"
read -rsp "  Cloudflare tunnel ID (or enter to skip): " CF_TUNNEL_ID; echo

# ── Write Phase 2 / 2.5 parameters ───────────────────────────────────────────

echo
echo -e "${BOLD}Writing SSM parameters...${RESET}"
echo

put_param \
  "${PREFIX}/okta/domain" \
  "$OKTA_DOMAIN" \
  "String" \
  "Okta tenant domain for Zero Trust Lab"

put_param \
  "${PREFIX}/okta/api-token" \
  "$OKTA_TOKEN" \
  "SecureString" \
  "Okta API token — used by Lambda to manage JIT users"

put_param \
  "${PREFIX}/okta/group-id" \
  "$OKTA_GROUP_ID" \
  "String" \
  "Okta JITDemo group ID — Lambda assigns JIT users to this group"

put_param \
  "${PREFIX}/cloudflare/zone-id" \
  "$CLOUDFLARE_ZONE_ID" \
  "String" \
  "Cloudflare zone ID for amitwebsite.online"

put_param \
  "${PREFIX}/cloudflare/account-id" \
  "$CLOUDFLARE_ACCOUNT_ID" \
  "String" \
  "Cloudflare account ID"

# ── Write Phase 3 parameters (if provided) ───────────────────────────────────

echo
if [[ -n "$GID_DEVTEAM" ]]; then
  put_param "${PREFIX}/okta/group-id-devteam"  "$GID_DEVTEAM"  "String" "Okta DevTeam group ID"
fi
if [[ -n "$GID_FINANCE" ]]; then
  put_param "${PREFIX}/okta/group-id-finance"  "$GID_FINANCE"  "String" "Okta FinanceTeam group ID"
fi
if [[ -n "$GID_DBADMINS" ]]; then
  put_param "${PREFIX}/okta/group-id-dbadmins" "$GID_DBADMINS" "String" "Okta DBAdmins group ID"
fi
if [[ -n "$GID_READONLY" ]]; then
  put_param "${PREFIX}/okta/group-id-readonly" "$GID_READONLY" "String" "Okta ReadOnly group ID"
fi
if [[ -n "$GID_ADMIN" ]]; then
  put_param "${PREFIX}/okta/group-id-admin"    "$GID_ADMIN"    "String" "Okta AdminTeam group ID"
fi
if [[ -n "$CF_TUNNEL_ID" ]]; then
  put_param "${PREFIX}/cloudflare/tunnel-id"   "$CF_TUNNEL_ID" "String" "Cloudflare tunnel ID for Phase 3"
fi

# ── Verify ────────────────────────────────────────────────────────────────────

echo
echo -e "${BOLD}Verifying parameters...${RESET}"
echo

PARAMS=$(aws ssm describe-parameters \
  --region "$REGION" \
  --parameter-filters "Key=Name,Option=BeginsWith,Values=${PREFIX}" \
  --query "Parameters[].Name" \
  --output text)

COUNT=$(echo "$PARAMS" | wc -w | tr -d ' ')
echo -e "${GREEN}${COUNT} parameters found under ${PREFIX}/${RESET}"
echo

for p in $PARAMS; do
  echo -e "  ${GREEN}✓${RESET} $p"
done

# ── Summary ───────────────────────────────────────────────────────────────────

echo
echo -e "${BOLD}═══════════════════════════════════════════════════════════${RESET}"
echo -e "${GREEN}${BOLD}  Bootstrap complete!${RESET}"
echo -e "${BOLD}═══════════════════════════════════════════════════════════${RESET}"
echo
echo -e "  Next steps:"
echo -e "  ${CYAN}1.${RESET} Ensure GitHub Secrets are set (production environment)"
echo -e "  ${CYAN}2.${RESET} terraform init -backend-config=\"bucket=\$TF_STATE_BUCKET\""
echo -e "  ${CYAN}3.${RESET} terraform plan"
echo -e "  ${CYAN}4.${RESET} terraform apply"
echo -e "  ${CYAN}5.${RESET} Update webapp/index.html CONFIG section with Terraform outputs"
echo
echo -e "  ${YELLOW}Migration note:${RESET} To migrate to a new account, re-run this"
echo -e "  script in the new account. Okta + Cloudflare values are unchanged."
echo
