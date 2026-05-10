################################################################################
# eventbridge.tf
# EventBridge Scheduler — JIT session revocation
# Phase 2 + 2.5 — Serverless stack
#
# What lives here:
#   Schedule group "zerotrust-jit" — container for per-session schedules
#   Lambda invoke permission — allows EventBridge Scheduler to invoke jit-revoker
#
# What does NOT live here:
#   Individual per-session schedules — these are created at RUNTIME by
#   jit-provisioner Lambda and deleted by jit-revoker after firing.
#   Terraform does not manage individual session schedules.
#
# Flow:
#   1. User hits POST /demo-access
#   2. jit-provisioner creates Okta user + creates a one-time schedule in
#      group "zerotrust-jit" firing at now + SESSION_DURATION seconds
#   3. EventBridge fires → invokes jit-revoker
#   4. jit-revoker deactivates + deletes Okta user + deletes the schedule
#
# Scheduler role (zerotrust-scheduler-role) is defined in iam.tf
################################################################################

################################################################################
# Schedule Group
# All per-session revocation schedules are created inside this group
# Group-level deletion would cascade — prevent_destroy guards against accidents
################################################################################

resource "aws_scheduler_schedule_group" "jit" {
  name = "zerotrust-jit"

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name    = "zerotrust-jit"
    Purpose = "Container for per-session JIT revocation schedules"
  }
}

################################################################################
# Lambda permission — allow EventBridge Scheduler to invoke jit-revoker
# source_arn scoped to zerotrust-jit group only
################################################################################

resource "aws_lambda_permission" "eventbridge_revoker" {
  statement_id  = "AllowEventBridgeSchedulerInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.jit_revoker.function_name
  principal     = "scheduler.amazonaws.com"
  source_arn    = "arn:aws:scheduler:${local.region}:${local.account_id}:schedule/zerotrust-jit/*"
}
