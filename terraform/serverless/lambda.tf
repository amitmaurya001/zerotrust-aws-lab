################################################################################
# lambda.tf
# Lambda functions for Phase 2 + 2.5 serverless stack
#
# Functions:
#   jit-provisioner   — POST /demo-access — creates Okta user + schedules revoke
#   jit-revoker       — EventBridge trigger — deletes Okta user + cleans up rule
#   session-checker   — GET /session-status + /session-count
#
# Packaging:
#   archive_file data sources zip lambda/ directory contents at plan time
#   Zips are written to /tmp/ and uploaded directly — no S3 staging needed
#   source_code_hash triggers redeployment when code changes
#
# Runtime: Python 3.12
# All functions share zerotrust-lambda-execution-role (defined in iam.tf)
#
# Environment variables passed to each function:
#   SSM paths — Lambda reads actual values from SSM at runtime (not here)
#   SCHEDULER_ROLE_ARN — jit-provisioner needs this to create EventBridge schedules
#   SCHEDULER_GROUP    — schedule group name
#   SESSION_DURATION   — seconds before jit-revoker fires
################################################################################

################################################################################
# Archive — zip Lambda source files at plan time
################################################################################

data "archive_file" "jit_provisioner" {
  type        = "zip"
  source_file = "${path.root}/../../lambda/jit_provisioner.py"
  output_path = "/tmp/jit_provisioner.zip"
}

data "archive_file" "jit_revoker" {
  type        = "zip"
  source_file = "${path.root}/../../lambda/jit_revoker.py"
  output_path = "/tmp/jit_revoker.zip"
}

data "archive_file" "session_checker" {
  type        = "zip"
  source_file = "${path.root}/../../lambda/session_checker.py"
  output_path = "/tmp/session_checker.zip"
}

################################################################################
# jit-provisioner
# Triggered by POST /demo-access (API Gateway)
# Handles both anonymous and Cognito paths based on Authorization header
################################################################################

resource "aws_lambda_function" "jit_provisioner" {
  function_name = local.fn_provisioner
  description   = "JIT Okta user provisioner — creates user, assigns JITDemo group, schedules revoke"
  role          = aws_iam_role.lambda_execution.arn

  filename         = data.archive_file.jit_provisioner.output_path
  source_code_hash = data.archive_file.jit_provisioner.output_base64sha256
  handler          = "jit_provisioner.lambda_handler"
  runtime          = var.lambda_runtime
  memory_size      = var.lambda_memory_mb
  timeout          = var.lambda_timeout_provisioner

  environment {
    variables = {
      SSM_OKTA_DOMAIN   = local.ssm_okta_domain
      SSM_OKTA_TOKEN    = local.ssm_okta_token
      SSM_OKTA_GROUP_ID = local.ssm_okta_group_id
      SCHEDULER_ROLE_ARN = aws_iam_role.scheduler.arn
      SCHEDULER_GROUP    = "zerotrust-jit"
      SESSION_DURATION   = tostring(var.jit_session_duration_seconds)
      WEBAPP_URL         = local.webapp_url
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_basic_execution,
    aws_cloudwatch_log_group.lambda_provisioner,
  ]

  tags = {
    Name    = local.fn_provisioner
    Purpose = "JIT provisioner — POST /demo-access"
  }
}

################################################################################
# jit-revoker
# Triggered by per-session EventBridge Scheduler rule (created by jit-provisioner)
# Deactivates + deletes Okta user, removes the schedule after firing
################################################################################

resource "aws_lambda_function" "jit_revoker" {
  function_name = local.fn_revoker
  description   = "JIT Okta user revoker — deactivates and deletes user, cleans up schedule"
  role          = aws_iam_role.lambda_execution.arn

  filename         = data.archive_file.jit_revoker.output_path
  source_code_hash = data.archive_file.jit_revoker.output_base64sha256
  handler          = "jit_revoker.lambda_handler"
  runtime          = var.lambda_runtime
  memory_size      = var.lambda_memory_mb
  timeout          = var.lambda_timeout_revoker

  environment {
    variables = {
      SSM_OKTA_DOMAIN = local.ssm_okta_domain
      SSM_OKTA_TOKEN  = local.ssm_okta_token
      SCHEDULER_GROUP = "zerotrust-jit"
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_basic_execution,
    aws_cloudwatch_log_group.lambda_revoker,
  ]

  tags = {
    Name    = local.fn_revoker
    Purpose = "JIT revoker — EventBridge Scheduler trigger"
  }
}

################################################################################
# session-checker
# GET /session-status — JWT authorizer (Okta), returns session state
# GET /session-count  — no auth, returns CloudWatch metric totals
################################################################################

resource "aws_lambda_function" "session_checker" {
  function_name = local.fn_checker
  description   = "Session checker — validates session state, returns CloudWatch counters"
  role          = aws_iam_role.lambda_execution.arn

  filename         = data.archive_file.session_checker.output_path
  source_code_hash = data.archive_file.session_checker.output_base64sha256
  handler          = "session_checker.lambda_handler"
  runtime          = var.lambda_runtime
  memory_size      = var.lambda_memory_mb
  timeout          = var.lambda_timeout_checker

  environment {
    variables = {
      SSM_OKTA_DOMAIN = local.ssm_okta_domain
      SSM_OKTA_TOKEN  = local.ssm_okta_token
    }
  }

  depends_on = [
    aws_iam_role_policy_attachment.lambda_basic_execution,
    aws_cloudwatch_log_group.lambda_checker,
  ]

  tags = {
    Name    = local.fn_checker
    Purpose = "Session checker — GET /session-status + /session-count"
  }
}

################################################################################
# Lambda permission — allow API Gateway to invoke each function
################################################################################

resource "aws_lambda_permission" "apigw_provisioner" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.jit_provisioner.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}

resource "aws_lambda_permission" "apigw_checker" {
  statement_id  = "AllowAPIGatewayInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.session_checker.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.main.execution_arn}/*/*"
}
