# Zero Trust Network Access Lab (ZTNA)

**Live demo:** [webapp.amitwebsite.online](https://webapp.amitwebsite.online)

A production-grade Zero Trust Network Access platform built on AWS, Cloudflare, and Okta — aligned with NIST SP 800-207. Demonstrates Just-In-Time (JIT) identity provisioning, ephemeral credential lifecycle management, and continuous compliance monitoring. The serverless JIT demo runs 24/7 at near-zero compute cost.

> Built with Claude Code (Anthropic) — agentic AI-driven DevOps. All infrastructure is code. No long-lived credentials anywhere.

---

## Architecture

```
User Browser
    |
    |-- webapp.amitwebsite.online (S3 via Cloudflare proxy)
    |       |
    |       |-- POST /demo-access --> API Gateway --> jit-provisioner Lambda
    |       |                                              |
    |       |                                    Create Okta JIT user
    |       |                                    Assign JITDemo group
    |       |                                    Create EventBridge schedule
    |       |
    |       |-- GET /session-count --> session-checker Lambda --> CloudWatch metrics
    |
    |-- Cognito Hosted UI (Google OAuth federation) --> Okta JIT
    |
    |-- private.amitwebsite.online (S3 via Cloudflare Access)
            |
            Cloudflare Access evaluates:
              - Okta OIDC groups claim (claim_name: groups, claim_value: JITDemo)
              - JWT claim evaluation
            |
            EventBridge fires at T+3min --> jit-revoker Lambda
              - Deactivates Okta user
              - Deletes Okta user
              - Seat revocation
```

Two distinct access paths:

**Path 1 — Anonymous JIT:** No login required. User clicks "Get anonymous access" — a temporary Okta account is provisioned instantly, assigned to the JITDemo group, and automatically deleted after 3 minutes via EventBridge and Lambda.

**Path 2 — Cognito + Okta JIT:** User authenticates via Cognito (supports Google OAuth federation). Real identity is logged to CloudWatch. JIT session is then provisioned identically to Path 1. Demonstrates layered identity — verified external identity alongside an ephemeral JIT account.

---

## Live Demo

Visit [webapp.amitwebsite.online](https://webapp.amitwebsite.online) to try both paths.

**What happens during a demo session:**

1. Click "Get anonymous access" (Path 1) or "Login with Cognito" (Path 2)
2. A temporary Okta account (`jit-xxxx@amitwebsite.online`) is created via Okta Management API
3. The account is assigned to the JITDemo group — granting Cloudflare Access
4. An EventBridge one-time schedule is created to fire at T+3 minutes
5. Credentials are displayed — use them on the Cloudflare Access login screen
6. Click "Access protected page" — opens `private.amitwebsite.online` (behind Cloudflare Access)
7. At T+3 minutes: jit-revoker Lambda fires, deactivates and deletes the Okta user
8. Session is revoked — access to the private page is lost

> **Tip:** Open the private page in an incognito window to ensure a fresh Cloudflare session.

---

## NIST SP 800-207 Coverage

| Pillar | Implementation |
|---|---|
| **1. Identity** | Okta OIDC + JIT ephemeral users + Cognito external identity layer |
| **2. Device** | Cloudflare WARP + device posture check (Phase 3) |
| **3. Network** | Cloudflare Access micro-perimeter + S3 IP allowlist (Cloudflare egress only) + zero inbound ports |
| **4. Application** | Cloudflare Access per-app policies + API Gateway JWT authorizer |
| **5. Data** | S3 SSE-S3 + SSM SecureString for all secrets + TLS everywhere |

---

## Technology Stack

| Layer | Technology |
|---|---|
| Edge / Zero Trust | Cloudflare Access, Cloudflare DNS (orange cloud proxy) |
| Identity | Okta OIDC (primary IdP), AWS Cognito (Path 2), Google OAuth (federated) |
| Compute | AWS Lambda (Python 3.12), API Gateway HTTP API |
| Scheduling | EventBridge Scheduler (per-session one-time schedules) |
| Secrets | AWS SSM Parameter Store (SecureString) |
| Observability | CloudWatch Logs, CloudWatch Metrics, CloudWatch Alarms, SNS alerts |
| Compliance | AWS Config (3 rules: S3 SSL, Lambda no public access, CloudTrail enabled) |
| Audit | AWS CloudTrail (API activity logging, management events) |
| AI (planned) | Amazon Bedrock — Claude Haiku 4.5 (daily security log analysis) |
| IaC | Terraform (AWS + Cloudflare providers) |
| CI/CD | GitHub Actions + OIDC trust (zero long-lived credentials) |

---

## Repository Structure

```
zerotrust-aws-lab/
├── .github/
│   └── workflows/
│       ├── deploy-serverless.yml   # Auto-deploy on push (Terraform + S3 sync)
│       └── deploy-servers.yml      # Manual-only (Phase 3 EC2/RDS)
├── terraform/
│   ├── serverless/                 # Phase 2/2.5 — all serverless resources
│   │   ├── backend.tf              # S3 remote state (partial config)
│   │   ├── variables.tf            # All inputs — no hardcoded secrets
│   │   ├── outputs.tf              # Post-deploy values for webapp CONFIG
│   │   ├── s3.tf                   # webapp + private + config_logs buckets
│   │   ├── cloudflare.tf           # Cloudflare IdP + Access app
│   │   ├── iam.tf                  # Lambda + scheduler + GitHub OIDC roles
│   │   ├── cognito.tf              # User pool + Google federation + hosted UI
│   │   ├── lambda.tf               # 3 Lambda functions
│   │   ├── apigateway.tf           # HTTP API + JWT authorizer + routes
│   │   ├── eventbridge.tf          # Schedule group (per-session schedules at runtime)
│   │   ├── cloudwatch.tf           # Log groups + alarms + dashboard + SNS
│   │   └── config.tf               # AWS Config recorder + delivery + rules
│   └── servers/                    # Phase 3 skeleton (EC2/RDS — not yet deployed)
│       ├── backend.tf
│       ├── variables.tf
│       └── outputs.tf
├── lambda/
│   ├── jit_provisioner.py          # POST /demo-access — creates Okta user + schedules revoke
│   ├── jit_revoker.py              # EventBridge trigger — deletes Okta user
│   ├── session_checker.py          # GET /session-status + /session-count
│   └── requirements.txt            # requests==2.31.0
├── webapp/
│   ├── index.html                  # JIT demo landing page
│   └── assets/
│       └── images/
│           ├── arch-diagram.png    # Architecture diagram
│           └── topmate.png         # Topmate logo
├── private-page/
│   ├── index.html                  # Protected resource (behind Cloudflare Access)
│   └── assets/
│       └── images/
│           └── topmate.png
├── scripts/
│   └── bootstrap-ssm.sh            # One-time SSM parameter population
├── screenshots/
│   └── .gitkeep
└── CLAUDE.md                       # AI context engineering for Claude Code
```

---

## Prerequisites

Before deploying, the following must exist:

**AWS (one-time manual setup):**
- S3 bucket for Terraform state (name stored in `TF_STATE_BUCKET` GitHub Secret)
- GitHub OIDC provider in IAM:
  ```bash
  aws iam create-open-id-connect-provider \
    --url https://token.actions.githubusercontent.com \
    --client-id-list sts.amazonaws.com \
    --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
  ```

**Okta:**
- Okta developer account (free tier)
- OIDC application ("Cloudflare Zero Trust") with groups claim configured
- JITDemo group created
- API token for Lambda (`/zerotrust/okta/api-token` in SSM)

**Cloudflare:**
- Domain (`amitwebsite.online`) managed by Cloudflare
- Zero Trust account (free plan)
- Manual Access policy "Allow JITDemo Users" using OIDC claim (`groups == JITDemo`)
- DNS records for `webapp` and `private` subdomains (orange cloud, managed manually)

**Google OAuth (for Cognito federation):**
- Google Cloud project with OAuth 2.0 client
- Authorized redirect URI: `https://amitztdemo-[account-id].auth.us-east-1.amazoncognito.com/oauth2/idpresponse`
- OAuth consent screen published (domain verification required)

---

## Deployment

### Step 1 — Bootstrap SSM parameters

Run once per AWS account before first Terraform apply:

```bash
chmod +x scripts/bootstrap-ssm.sh
./scripts/bootstrap-ssm.sh
```

This populates all `/zerotrust/` SSM parameters interactively:
- `/zerotrust/okta/domain`
- `/zerotrust/okta/api-token` (SecureString)
- `/zerotrust/okta/group-id`
- `/zerotrust/cloudflare/account-id`
- `/zerotrust/cloudflare/zone-id`

### Step 2 — Import existing S3 buckets (first deploy only)

If the webapp and private S3 buckets already exist:

```bash
cd terraform/serverless
terraform init -backend-config="bucket=YOUR_STATE_BUCKET"
terraform import aws_s3_bucket.webapp webapp.amitwebsite.online
terraform import aws_s3_bucket.private private.amitwebsite.online
terraform import aws_s3_bucket_website_configuration.webapp webapp.amitwebsite.online
terraform import aws_s3_bucket_website_configuration.private private.amitwebsite.online
terraform import aws_s3_bucket_public_access_block.webapp webapp.amitwebsite.online
terraform import aws_s3_bucket_public_access_block.private private.amitwebsite.online
```

### Step 3 — Set GitHub Secrets

In your GitHub repository → Settings → Environments → `production`, add:

| Secret | Description |
|---|---|
| `AWS_ROLE_ARN_SERVERLESS` | ARN of the GitHub OIDC deploy role |
| `TF_STATE_BUCKET` | S3 bucket name for Terraform state |
| `CLOUDFLARE_API_TOKEN` | Cloudflare API token |
| `CLOUDFLARE_ACCOUNT_ID` | Cloudflare account ID |
| `CLOUDFLARE_ZONE_ID` | Cloudflare zone ID |
| `OKTA_DOMAIN` | Okta tenant domain |
| `OKTA_CLIENT_ID` | Okta OIDC app client ID |
| `OKTA_CLIENT_SECRET` | Okta OIDC app client secret |
| `ALERT_EMAIL` | Email for CloudWatch SNS alerts |

### Step 4 — Deploy

Push to `main` — GitHub Actions triggers automatically:

```bash
git push origin main
```

The `deploy-serverless` workflow:
1. Builds Lambda package (installs `requests` dependency)
2. `terraform init` (pulls state from S3)
3. `terraform validate`
4. `terraform plan`
5. Manual approval gate (GitHub Environment: production)
6. `terraform apply`
7. Syncs `webapp/index.html` and `private-page/index.html` to S3

### Step 5 — Post-deploy configuration

After first apply, run `terraform output deploy_instructions` and update the CONFIG section in `webapp/index.html`:

```javascript
var API_URL           = '<api_gateway_url from output>';
var COGNITO_CLIENT_ID = '<cognito_client_id from output>';
var COGNITO_DOMAIN    = '<cognito_domain from output>';
```

Commit and push — the workflow syncs the updated HTML to S3 automatically.

---

## Migration to a New AWS Account

This project is designed for easy account migration:

1. Create S3 state bucket in new account
2. Create GitHub OIDC provider (one command above)
3. Update GitHub Secrets: `AWS_ROLE_ARN_SERVERLESS`, `TF_STATE_BUCKET`
4. Run `bootstrap-ssm.sh` in new account (Okta/Cloudflare values unchanged)
5. Push to `main` — Terraform recreates everything from scratch

Okta, Cloudflare, and GitHub configuration are unchanged. No file edits required.

---

## Known Limitations and Design Decisions

**Cloudflare Access — session expires immediately:**
Session duration is set to "No duration, expires immediately" — each new browser visit
to the private page requires fresh Cloudflare Access authentication. Combined with
3-minute Okta user deletion via EventBridge/Lambda, access is fully revoked at both
the identity layer (Okta) and the session layer (Cloudflare).

**End-to-end encryption:**
All traffic is TLS-encrypted at every layer:
- User to Cloudflare edge: HTTPS enforced via "Always Use HTTPS" (Cloudflare Edge Certificate)
- Cloudflare to S3: HTTP on the internal leg (S3 website endpoints do not support HTTPS) — mitigated by Cloudflare IP allowlist blocking all non-Cloudflare access to S3 directly
- API Gateway: HTTPS only (AWS managed TLS)
- Lambda to Okta API: HTTPS (requests library, TLS verified)
- Lambda to SSM: AWS internal encrypted channel
- S3 buckets: AES-256 server-side encryption at rest

**Cloudflare Access seats:**
Each unique user who authenticates consumes a seat (50 seats on free plan). JIT users persist in Cloudflare's user registry even after Okta deletion. Manually revoke via Zero Trust dashboard periodically to free seats.

**Bedrock access (India accounts):**
AWS Marketplace model subscriptions may not work with UPI payment methods. Use direct Anthropic API as an alternative for the AI log analysis feature.

---

## CI/CD

Two workflows:

**`deploy-serverless.yml`** — triggers automatically on push to `main` when files in `terraform/serverless/`, `lambda/`, `webapp/`, or `private-page/` change. Requires manual approval in GitHub Environment `production` before apply.

**`deploy-servers.yml`** — manual trigger only (`workflow_dispatch`). Requires explicit action selection (`plan-only`, `apply`, `destroy`) and confirmation string. Includes cost reminder after apply — Phase 3 servers accrue cost and must be destroyed after use.

---

## Security Design

**Zero long-lived credentials:** GitHub Actions assumes the deploy role via OIDC. Lambda reads secrets from SSM at runtime. No credentials in code, environment variables (plaintext), or repository.

**Least privilege:** Lambda execution role scoped to `/zerotrust/*` SSM paths, `ZeroTrust/JIT` CloudWatch namespace, and `zerotrust-jit` EventBridge schedule group only. Scheduler role can only invoke `jit-revoker`.

**GitHub OIDC trust** locked to `repo:amitmaurya001/zerotrust-aws-lab:environment:production` — no other repositories or branches can assume the deploy role.

**S3 bucket protection:** Both ZTNA buckets have `prevent_destroy = true` in Terraform. Access restricted to Cloudflare egress IP ranges only.

---

## Compliance

AWS Config runs continuously with three managed rules:

| Rule | What it monitors |
|---|---|
| `cloudtrail-enabled` | CloudTrail must be active in the account |
| `lambda-function-public-access-prohibited` | Lambda functions must not have public resource policies |
| `s3-bucket-ssl-requests-only` | S3 buckets must enforce SSL-only requests |

The `s3-bucket-ssl-requests-only` rule intentionally shows non-compliant for `webapp` and `private` buckets. These buckets use Cloudflare Flexible SSL — the Cloudflare-to-S3 leg is HTTP (S3 website endpoints do not support HTTPS), while the public-facing connection is always HTTPS enforced at the Cloudflare edge via "Always Use HTTPS". The Cloudflare IP allowlist on both buckets prevents any direct non-Cloudflare access entirely. This is a documented, intentional design decision, not a gap.

Config snapshots and compliance history are delivered to `aws-config-zerotrust-[account-id]` S3 bucket with 90-day lifecycle.

---

## Cost

Approximate monthly cost at demo traffic levels (~100 sessions/month):

| Service | Cost |
|---|---|
| Lambda (3 functions) | Free tier |
| API Gateway | Free tier |
| EventBridge Scheduler | Free tier |
| CloudWatch | Free tier |
| S3 (3 buckets, ~5MB) | ~$0.01 |
| Cognito (< 50K MAU) | Free tier |
| SSM Parameter Store | Free tier |
| **Total** | **~$0.01 - $0.56/month** |

Cloudflare, Okta developer, and GitHub Actions are all free tier.

---

## Author

**Amit Maurya** — Cloud & AI Security Architect

- Portfolio: [amitwebsite.online](https://amitwebsite.online)
- LinkedIn: [linkedin.com/in/amitmaurya](https://www.linkedin.com/in/amitmaurya)
- GitHub: [github.com/amitmaurya001](https://github.com/amitmaurya001)
- Topmate: [topmate.io/amit_maurya01](https://topmate.io/amit_maurya01)

---

*Built with Claude Code — Anthropic's agentic coding tool. All infrastructure as code. NIST SP 800-207 aligned.*
