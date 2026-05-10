"""
session_checker.py
Triggered by:
  GET /session-status  — JWT authorizer (Okta) — returns session state + identity
  GET /session-count   — no auth — returns total provisioned/deleted from CloudWatch

Route is distinguished by rawPath in the event:
  /session-status → check if Okta user still exists, return time remaining
  /session-count  → read CloudWatch metrics, return counters

Timeout: 10 seconds
"""

import json
import os
import datetime
import boto3
import requests

# ── AWS clients ──────────────────────────────────────────────────────────────

ssm = boto3.client("ssm",        region_name=os.environ.get("AWS_REGION", "us-east-1"))
cw  = boto3.client("cloudwatch", region_name=os.environ.get("AWS_REGION", "us-east-1"))

# ── Environment variables ─────────────────────────────────────────────────────

SSM_OKTA_DOMAIN = os.environ["SSM_OKTA_DOMAIN"]
SSM_OKTA_TOKEN  = os.environ["SSM_OKTA_TOKEN"]
WEBAPP_URL      = os.environ.get("WEBAPP_URL", "https://webapp.amitwebsite.online")

# ── SSM cache ─────────────────────────────────────────────────────────────────

_ssm_cache: dict = {}

def _get_ssm(path: str) -> str:
    if path not in _ssm_cache:
        resp = ssm.get_parameter(Name=path, WithDecryption=True)
        _ssm_cache[path] = resp["Parameter"]["Value"]
    return _ssm_cache[path]

# ── CORS helpers ──────────────────────────────────────────────────────────────

def _cors() -> dict:
    return {
        "Access-Control-Allow-Origin":      WEBAPP_URL,
        "Access-Control-Allow-Headers":     "Content-Type,Authorization",
        "Access-Control-Allow-Methods":     "GET,OPTIONS",
        "Access-Control-Allow-Credentials": "true",
    }

def _resp(status: int, body: dict) -> dict:
    return {
        "statusCode": status,
        "headers":    {**_cors(), "Content-Type": "application/json"},
        "body":       json.dumps(body),
    }

# ── Okta helpers ──────────────────────────────────────────────────────────────

def _okta_headers(token: str) -> dict:
    return {
        "Authorization": f"SSWS {token}",
        "Accept":        "application/json",
    }

def _get_okta_user_by_login(domain: str, token: str, email: str) -> dict | None:
    """Look up Okta user by login (email). Returns user dict or None if not found."""
    url  = f"https://{domain}/api/v1/users/{email}"
    resp = requests.get(url, headers=_okta_headers(token), timeout=8)
    if resp.status_code == 200:
        return resp.json()
    if resp.status_code == 404:
        return None
    resp.raise_for_status()
    return None

# ── CloudWatch metric readers ─────────────────────────────────────────────────

def _get_metric_sum(metric_name: str) -> int:
    """Read cumulative sum of a ZeroTrust/JIT metric over the past year."""
    try:
        now   = datetime.datetime.utcnow()
        start = now - datetime.timedelta(days=365)
        resp  = cw.get_metric_statistics(
            Namespace  = "ZeroTrust/JIT",
            MetricName = metric_name,
            Dimensions = [{"Name": "Environment", "Value": "prod"}],
            StartTime  = start,
            EndTime    = now,
            Period     = 86400 * 365,
            Statistics = ["Sum"],
        )
        if resp["Datapoints"]:
            return int(resp["Datapoints"][0]["Sum"])
    except Exception as e:
        print(f"[WARN] CloudWatch read failed for {metric_name}: {e}")
    return 0

# ── Route handlers ────────────────────────────────────────────────────────────

def _handle_session_status(event: dict) -> dict:
    """
    GET /session-status
    JWT authorizer has already validated the Okta access token.
    We extract the email from the JWT claims (passed by API GW in requestContext)
    and check whether the Okta user still exists.
    """
    # API Gateway HTTP API JWT authorizer puts claims in requestContext.authorizer.jwt.claims
    claims = (
        event.get("requestContext", {})
             .get("authorizer", {})
             .get("jwt", {})
             .get("claims", {})
    )
    email = claims.get("sub") or claims.get("email")
    exp   = claims.get("exp")

    if not email:
        return _resp(400, {"error": "No identity in JWT claims"})

    # Read SSM
    try:
        okta_domain = _get_ssm(SSM_OKTA_DOMAIN)
        okta_token  = _get_ssm(SSM_OKTA_TOKEN)
    except Exception as e:
        return _resp(500, {"error": "Config error", "detail": str(e)})

    # Check if user still exists in Okta
    try:
        user = _get_okta_user_by_login(okta_domain, okta_token, email)
    except Exception as e:
        return _resp(502, {"error": "Okta lookup failed", "detail": str(e)})

    now_ts = int(datetime.datetime.utcnow().timestamp())

    if user is None:
        # User deleted — session revoked
        return _resp(200, {
            "active":       False,
            "email":        email,
            "status":       "revoked",
            "time_remaining": 0,
        })

    # User still exists — calculate time remaining from JWT exp
    time_remaining = max(0, int(exp) - now_ts) if exp else None

    return _resp(200, {
        "active":         True,
        "email":          email,
        "okta_status":    user.get("status", "ACTIVE"),
        "status":         "active",
        "time_remaining": time_remaining,
    })


def _handle_session_count() -> dict:
    """
    GET /session-count
    No auth. Returns total sessions provisioned and deleted from CloudWatch metrics.
    """
    total_created = _get_metric_sum("UserCreated")
    total_deleted = _get_metric_sum("UserDeleted")

    return _resp(200, {
        "sessions_provisioned": total_created,
        "sessions_deleted":     total_deleted,
        "persistent_accounts":  0,  # Always 0 — core ZTNA demonstration
    })

# ── Lambda handler ────────────────────────────────────────────────────────────

def lambda_handler(event: dict, context) -> dict:
    # CORS preflight
    method = event.get("requestContext", {}).get("http", {}).get("method", "")
    if method == "OPTIONS":
        return {"statusCode": 200, "headers": _cors(), "body": ""}

    path = event.get("rawPath", "")

    if path == "/session-status":
        return _handle_session_status(event)

    if path == "/session-count":
        return _handle_session_count()

    return _resp(404, {"error": f"Unknown route: {path}"})
