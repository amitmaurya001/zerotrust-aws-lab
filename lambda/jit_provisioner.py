"""
jit_provisioner.py
Triggered by POST /demo-access via API Gateway HTTP API

Handles two paths based on Authorization header:
  PATH 1 — Anonymous:  no Authorization header → create JIT user, return credentials
  PATH 2 — Cognito:   Bearer <token> → validate Cognito JWT, log identity, create JIT user

SSM Parameters read at runtime (not at cold start):
  /zerotrust/okta/domain      — Okta tenant domain
  /zerotrust/okta/api-token   — SSWS token for Okta Management API
  /zerotrust/okta/group-id    — JITDemo group ID

Returns to caller:
  email, password, session_number, log_lines, expires_in, country

Emits CloudWatch metric: ZeroTrust/JIT namespace, UserCreated metric

NEVER hardcode Okta credentials here — always read from SSM
"""

import json
import os
import uuid
import boto3
import requests
import urllib.request
import base64
import time
import datetime

# ── AWS clients ──────────────────────────────────────────────────────────────

ssm      = boto3.client("ssm",          region_name=os.environ.get("AWS_REGION", "us-east-1"))
sched    = boto3.client("scheduler",    region_name=os.environ.get("AWS_REGION", "us-east-1"))
cw       = boto3.client("cloudwatch",   region_name=os.environ.get("AWS_REGION", "us-east-1"))

# ── Environment variables (set by Terraform lambda.tf) ───────────────────────

SSM_OKTA_DOMAIN   = os.environ["SSM_OKTA_DOMAIN"]
SSM_OKTA_TOKEN    = os.environ["SSM_OKTA_TOKEN"]
SSM_OKTA_GROUP_ID = os.environ["SSM_OKTA_GROUP_ID"]
SCHEDULER_ROLE_ARN = os.environ["SCHEDULER_ROLE_ARN"]
SCHEDULER_GROUP    = os.environ.get("SCHEDULER_GROUP", "zerotrust-jit")
SESSION_DURATION   = int(os.environ.get("SESSION_DURATION", "180"))
WEBAPP_URL         = os.environ.get("WEBAPP_URL", "https://webapp.amitwebsite.online")

# ── Module-level SSM cache (avoids repeated SSM calls on warm invocations) ───

_ssm_cache: dict = {}

def _get_ssm(path: str) -> str:
    if path not in _ssm_cache:
        resp = ssm.get_parameter(Name=path, WithDecryption=True)
        _ssm_cache[path] = resp["Parameter"]["Value"]
    return _ssm_cache[path]

# ── CORS headers ──────────────────────────────────────────────────────────────

def _cors(origin: str | None) -> dict:
    allowed = WEBAPP_URL
    return {
        "Access-Control-Allow-Origin":      allowed,
        "Access-Control-Allow-Headers":     "Content-Type,Authorization",
        "Access-Control-Allow-Methods":     "POST,OPTIONS",
        "Access-Control-Allow-Credentials": "true",
    }

def _resp(status: int, body: dict, origin: str | None = None) -> dict:
    return {
        "statusCode": status,
        "headers":    {**_cors(origin), "Content-Type": "application/json"},
        "body":       json.dumps(body),
    }

# ── Okta helpers ──────────────────────────────────────────────────────────────

def _okta_headers(token: str) -> dict:
    return {
        "Authorization": f"SSWS {token}",
        "Content-Type":  "application/json",
        "Accept":        "application/json",
    }

def _create_okta_user(domain: str, token: str, email: str, password: str) -> dict:
    """Create an active Okta user directly (no activation email)."""
    url  = f"https://{domain}/api/v1/users?activate=true"
    body = {
        "profile": {
            "firstName": "JIT",
            "lastName":  "Demo",
            "email":     email,
            "login":     email,
        },
        "credentials": {
            "password": {"value": password}
        },
    }
    resp = requests.post(url, headers=_okta_headers(token), json=body, timeout=10)
    if resp.status_code not in (200, 201):
        raise RuntimeError(f"Okta create user failed {resp.status_code}: {resp.text[:200]}")
    return resp.json()

def _assign_okta_group(domain: str, token: str, user_id: str, group_id: str) -> None:
    """Assign user to JITDemo group."""
    url  = f"https://{domain}/api/v1/groups/{group_id}/users/{user_id}"
    resp = requests.put(url, headers=_okta_headers(token), timeout=10)
    if resp.status_code not in (200, 204):
        raise RuntimeError(f"Okta group assign failed {resp.status_code}: {resp.text[:200]}")

# ── Cognito JWT validation ─────────────────────────────────────────────────────

def _validate_cognito_jwt(token: str) -> dict | None:
    """
    Minimal JWT decode — extracts payload without full signature verification.
    Cloudflare Access + API Gateway JWT authorizer handle cryptographic validation.
    We only need the email claim for logging.
    """
    try:
        parts = token.split(".")
        if len(parts) != 3:
            return None
        payload_b64 = parts[1]
        # Add padding
        payload_b64 += "=" * (4 - len(payload_b64) % 4)
        payload = json.loads(base64.urlsafe_b64decode(payload_b64))
        return payload
    except Exception:
        return None

# ── EventBridge Scheduler ─────────────────────────────────────────────────────

def _schedule_revoke(session_id: str, okta_user_id: str, okta_email: str, fn_revoker_arn: str) -> None:
    """
    Create a one-time EventBridge schedule to fire jit-revoker in SESSION_DURATION seconds.
    Schedule name: jit-{session_id} (unique per session)
    """
    fire_at = datetime.datetime.utcnow() + datetime.timedelta(seconds=SESSION_DURATION)
    # EventBridge Scheduler uses at() expression for one-time schedules
    schedule_expr = f"at({fire_at.strftime('%Y-%m-%dT%H:%M:%S')})"

    sched.create_schedule(
        Name        = f"jit-{session_id}",
        GroupName   = SCHEDULER_GROUP,
        ScheduleExpression         = schedule_expr,
        ScheduleExpressionTimezone = "UTC",
        FlexibleTimeWindow         = {"Mode": "OFF"},
        Target = {
            "Arn":     fn_revoker_arn,
            "RoleArn": SCHEDULER_ROLE_ARN,
            "Input":   json.dumps({
                "session_id":    session_id,
                "okta_user_id":  okta_user_id,
                "okta_email":    okta_email,
                "schedule_name": f"jit-{session_id}",
            }),
        },
        # Delete schedule after it fires — avoids manual cleanup if revoker misses it
        ActionAfterCompletion = "DELETE",
    )

# ── CloudWatch metric ─────────────────────────────────────────────────────────

def _emit_created_metric(session_number: int) -> None:
    try:
        cw.put_metric_data(
            Namespace  = "ZeroTrust/JIT",
            MetricData = [{
                "MetricName": "UserCreated",
                "Value":      1,
                "Unit":       "Count",
                "Dimensions": [{"Name": "Environment", "Value": "prod"}],
            }],
        )
    except Exception:
        pass  # Never let metric failure break the provisioning flow

# ── Session counter (read from CloudWatch) ───────────────────────────────────

def _get_session_number() -> int:
    """Approximate session number from CloudWatch metric sum."""
    try:
        now   = datetime.datetime.utcnow()
        start = now - datetime.timedelta(days=365)
        resp  = cw.get_metric_statistics(
            Namespace  = "ZeroTrust/JIT",
            MetricName = "UserCreated",
            Dimensions = [{"Name": "Environment", "Value": "prod"}],
            StartTime  = start,
            EndTime    = now,
            Period     = 86400 * 365,
            Statistics = ["Sum"],
        )
        if resp["Datapoints"]:
            return int(resp["Datapoints"][0]["Sum"]) + 1
    except Exception:
        pass
    return 1

# ── Country from IP ───────────────────────────────────────────────────────────

def _country_from_ip(ip: str) -> str:
    """Best-effort geolocation via ipapi.co — fail silently."""
    try:
        with urllib.request.urlopen(f"https://ipapi.co/{ip}/country_name/", timeout=3) as r:
            return r.read().decode().strip() or "Unknown"
    except Exception:
        return "Unknown"

# ── Lambda handler ────────────────────────────────────────────────────────────

def lambda_handler(event: dict, context) -> dict:
    origin = (event.get("headers") or {}).get("origin")

    # Handle CORS preflight
    if event.get("requestContext", {}).get("http", {}).get("method") == "OPTIONS":
        return {"statusCode": 200, "headers": _cors(origin), "body": ""}

    # ── Read SSM ──────────────────────────────────────────────────────────────
    try:
        okta_domain   = _get_ssm(SSM_OKTA_DOMAIN)
        okta_token    = _get_ssm(SSM_OKTA_TOKEN)
        okta_group_id = _get_ssm(SSM_OKTA_GROUP_ID)
    except Exception as e:
        return _resp(500, {"error": "Configuration error", "detail": str(e)}, origin)

    # ── Detect path: Cognito or anonymous ────────────────────────────────────
    auth_header   = (event.get("headers") or {}).get("authorization", "")
    cognito_email = None
    cognito_path  = False

    if auth_header.lower().startswith("bearer "):
        token   = auth_header[7:]
        payload = _validate_cognito_jwt(token)
        if payload and payload.get("email"):
            cognito_email = payload["email"]
            cognito_path  = True

    # ── Source IP + country ───────────────────────────────────────────────────
    source_ip = (
        event.get("requestContext", {}).get("http", {}).get("sourceIp", "")
        or event.get("headers", {}).get("x-forwarded-for", "").split(",")[0].strip()
    )
    country = _country_from_ip(source_ip) if source_ip else "Unknown"

    # ── Generate JIT credentials ──────────────────────────────────────────────
    session_id = str(uuid.uuid4()).replace("-", "")[:12]
    jit_email  = f"jit-{session_id}@amitwebsite.online"
    jit_passwd = f"JIT-{uuid.uuid4().hex[:12]}!"   # Always meets Okta complexity

    # ── Create Okta user ──────────────────────────────────────────────────────
    try:
        user = _create_okta_user(okta_domain, okta_token, jit_email, jit_passwd)
    except Exception as e:
        return _resp(502, {"error": "Failed to create JIT user", "detail": str(e)}, origin)

    okta_user_id = user["id"]

    # ── Assign JITDemo group ──────────────────────────────────────────────────
    try:
        _assign_okta_group(okta_domain, okta_token, okta_user_id, okta_group_id)
    except Exception as e:
        # Best-effort delete the orphaned user before returning error
        try:
            requests.post(
                f"https://{okta_domain}/api/v1/users/{okta_user_id}/lifecycle/deactivate",
                headers=_okta_headers(okta_token), timeout=5
            )
            requests.delete(
                f"https://{okta_domain}/api/v1/users/{okta_user_id}",
                headers=_okta_headers(okta_token), timeout=5
            )
        except Exception:
            pass
        return _resp(502, {"error": "Failed to assign JITDemo group", "detail": str(e)}, origin)

    # ── Get jit-revoker ARN from context (Lambda function ARN pattern) ────────
    # Derive revoker ARN from current function ARN (same account/region)
    own_arn     = context.invoked_function_arn
    arn_parts   = own_arn.split(":")
    account_id  = arn_parts[4]
    region      = arn_parts[3]
    fn_revoker_arn = f"arn:aws:lambda:{region}:{account_id}:function:jit-revoker"

    # ── Schedule EventBridge revocation ──────────────────────────────────────
    try:
        _schedule_revoke(session_id, okta_user_id, jit_email, fn_revoker_arn)
    except Exception as e:
        # User is provisioned but won't auto-revoke — surface this clearly
        return _resp(500, {
            "error":  "User created but revocation schedule failed",
            "detail": str(e),
            "email":  jit_email,
        }, origin)

    # ── Session number + metric ───────────────────────────────────────────────
    session_number = _get_session_number()
    _emit_created_metric(session_number)

    # ── Build audit log lines (displayed in webapp terminal) ─────────────────
    ts = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")
    log_lines = [
        f"[{ts}] SESSION #{session_number} INITIATED",
        f"[{ts}] source_ip={source_ip or 'unknown'} country={country}",
        f"[{ts}] path={'cognito' if cognito_path else 'anonymous'}",
    ]
    if cognito_path and cognito_email:
        log_lines.append(f"[{ts}] cognito_identity={cognito_email}")
    log_lines += [
        f"[{ts}] okta_user_id={okta_user_id}",
        f"[{ts}] jit_email={jit_email}",
        f"[{ts}] group=JITDemo",
        f"[{ts}] session_duration={SESSION_DURATION}s",
        f"[{ts}] revoke_schedule=jit-{session_id}",
        f"[{ts}] status=PROVISIONED",
    ]

    # ── Response ──────────────────────────────────────────────────────────────
    response_body = {
        "email":          jit_email,
        "password":       jit_passwd,
        "session_number": session_number,
        "session_id":     session_id,
        "expires_in":     SESSION_DURATION,
        "country":        country,
        "log_lines":      log_lines,
        "path":           "cognito" if cognito_path else "anonymous",
    }
    if cognito_path and cognito_email:
        response_body["cognito_email"] = cognito_email

    return _resp(200, response_body, origin)
