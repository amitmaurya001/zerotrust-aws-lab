"""
jit_revoker.py
Triggered by EventBridge Scheduler — one schedule per JIT session,
created dynamically by jit_provisioner at runtime.

Input event (from EventBridge, set by jit_provisioner):
  {
    "session_id":    "abc123",
    "okta_user_id":  "00u...",
    "okta_email":    "jit-abc123@amitwebsite.online",
    "schedule_name": "jit-abc123"
  }

Steps:
  1. Read Okta credentials from SSM
  2. Deactivate Okta user (required before delete)
  3. Delete Okta user
  4. Emit CloudWatch metric ZeroTrust/JIT/UserDeleted
  (EventBridge schedule auto-deletes after firing — ActionAfterCompletion=DELETE set by provisioner)

Timeout: 60 seconds (longer for cleanup resilience)
Retries: Lambda will retry on failure — Okta calls are idempotent for deactivate/delete
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
SCHEDULER_GROUP = os.environ.get("SCHEDULER_GROUP", "zerotrust-jit")

# ── SSM cache ─────────────────────────────────────────────────────────────────

_ssm_cache: dict = {}

def _get_ssm(path: str) -> str:
    if path not in _ssm_cache:
        resp = ssm.get_parameter(Name=path, WithDecryption=True)
        _ssm_cache[path] = resp["Parameter"]["Value"]
    return _ssm_cache[path]

# ── Okta helpers ──────────────────────────────────────────────────────────────

def _okta_headers(token: str) -> dict:
    return {
        "Authorization": f"SSWS {token}",
        "Content-Type":  "application/json",
        "Accept":        "application/json",
    }

def _deactivate_user(domain: str, token: str, user_id: str) -> bool:
    """
    Deactivate Okta user — required step before delete.
    Returns True on success, False if user already deactivated/not found (idempotent).
    """
    url  = f"https://{domain}/api/v1/users/{user_id}/lifecycle/deactivate"
    resp = requests.post(url, headers=_okta_headers(token), timeout=15)
    if resp.status_code in (200, 204):
        return True
    if resp.status_code == 404:
        # User already deleted — treat as success
        print(f"[INFO] User {user_id} not found during deactivate — already deleted")
        return True
    if resp.status_code == 400:
        # User may already be deactivated — proceed to delete
        print(f"[INFO] Deactivate returned 400 for {user_id} — attempting delete anyway")
        return True
    print(f"[WARN] Deactivate failed for {user_id}: {resp.status_code} {resp.text[:200]}")
    return False

def _delete_user(domain: str, token: str, user_id: str) -> bool:
    """
    Delete Okta user. Returns True on success or 404 (already gone).
    """
    url  = f"https://{domain}/api/v1/users/{user_id}"
    resp = requests.delete(url, headers=_okta_headers(token), timeout=15)
    if resp.status_code in (200, 204):
        return True
    if resp.status_code == 404:
        print(f"[INFO] User {user_id} not found during delete — already gone")
        return True
    print(f"[WARN] Delete failed for {user_id}: {resp.status_code} {resp.text[:200]}")
    return False

# ── CloudWatch metric ─────────────────────────────────────────────────────────

def _emit_deleted_metric() -> None:
    try:
        cw.put_metric_data(
            Namespace  = "ZeroTrust/JIT",
            MetricData = [{
                "MetricName": "UserDeleted",
                "Value":      1,
                "Unit":       "Count",
                "Dimensions": [{"Name": "Environment", "Value": "prod"}],
            }],
        )
    except Exception as e:
        print(f"[WARN] CloudWatch metric emit failed: {e}")

# ── Lambda handler ────────────────────────────────────────────────────────────

def lambda_handler(event: dict, context) -> dict:
    ts = datetime.datetime.utcnow().strftime("%Y-%m-%dT%H:%M:%SZ")

    # EventBridge passes our input JSON directly as the event
    session_id    = event.get("session_id",    "unknown")
    okta_user_id  = event.get("okta_user_id")
    okta_email    = event.get("okta_email",    "unknown")
    schedule_name = event.get("schedule_name")

    print(f"[{ts}] REVOKER TRIGGERED session_id={session_id} user_id={okta_user_id} email={okta_email}")

    if not okta_user_id:
        print(f"[ERROR] No okta_user_id in event — cannot revoke")
        return {"status": "error", "reason": "missing okta_user_id"}

    # ── Read SSM ──────────────────────────────────────────────────────────────
    try:
        okta_domain = _get_ssm(SSM_OKTA_DOMAIN)
        okta_token  = _get_ssm(SSM_OKTA_TOKEN)
    except Exception as e:
        print(f"[ERROR] SSM read failed: {e}")
        raise  # Re-raise so Lambda retries

    # ── Deactivate ────────────────────────────────────────────────────────────
    deactivated = _deactivate_user(okta_domain, okta_token, okta_user_id)
    print(f"[{ts}] deactivate={'OK' if deactivated else 'FAILED'} user_id={okta_user_id}")

    # ── Delete ────────────────────────────────────────────────────────────────
    deleted = _delete_user(okta_domain, okta_token, okta_user_id)
    print(f"[{ts}] delete={'OK' if deleted else 'FAILED'} user_id={okta_user_id}")

    # ── Emit metric ───────────────────────────────────────────────────────────
    if deleted:
        _emit_deleted_metric()
        print(f"[{ts}] metric=UserDeleted emitted")

    print(f"[{ts}] REVOCATION COMPLETE session_id={session_id} email={okta_email}")

    return {
        "status":      "revoked" if deleted else "partial",
        "session_id":  session_id,
        "okta_email":  okta_email,
        "deactivated": deactivated,
        "deleted":     deleted,
    }
