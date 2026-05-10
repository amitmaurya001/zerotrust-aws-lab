################################################################################
# iam.tf
# IAM roles and policies for Phase 2 + 2.5 serverless stack
#
# Roles:
#   zerotrust-lambda-execution-role   - assumed by all 3 Lambda functions
#   zerotrust-scheduler-role          - assumed by EventBridge Scheduler
#                                       to invoke jit-revoker per JIT session
#   zerotrust-serverless-deploy-role  - assumed by GitHub Actions OIDC
#
# Principle of least privilege:
#   Lambda: SSM read (/zerotrust/* only), EventBridge scheduler create/delete,
#           CloudWatch metrics (ZeroTrust/JIT namespace only) + logs
#   Scheduler: InvokeFunction on jit-revoker only
#   Deploy role: serverless resources only - no EC2/RDS perms
#
# GitHub OIDC:
#   No long-lived credentials
#   Locked to repo:amitmaurya001/zerotrust-aws-lab + environment:production
#
# PRE-REQUISITE - create OIDC provider once per account before first apply:
#   aws iam create-open-id-connect-provider \
#     --url https://token.actions.githubusercontent.com \
#     --client-id-list sts.amazonaws.com \
#     --thumbprint-list 6938fd4d98bab03faadb97b34396831e3780aea1
################################################################################

################################################################################
# Lambda Execution Role
################################################################################

data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "lambda_execution" {
  name               = "zerotrust-lambda-execution-role"
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
  description        = "Execution role for jit-provisioner, jit-revoker, session-checker"

  tags = {
    Name    = "zerotrust-lambda-execution-role"
    Purpose = "Lambda execution - all three ZTNA functions"
  }
}

resource "aws_iam_role_policy_attachment" "lambda_basic_execution" {
  role       = aws_iam_role.lambda_execution.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

data "aws_iam_policy_document" "lambda_permissions" {

  # SSM - read /zerotrust/* parameters only
  statement {
    sid     = "SSMReadZeroTrustParams"
    effect  = "Allow"
    actions = ["ssm:GetParameter", "ssm:GetParameters"]
    resources = [
      "arn:aws:ssm:${local.region}:${local.account_id}:parameter/zerotrust/*"
    ]
  }

  # KMS - decrypt SSM SecureString (AWS managed key)
  statement {
    sid     = "KMSDecryptSSM"
    effect  = "Allow"
    actions = ["kms:Decrypt"]
    resources = [
      "arn:aws:kms:${local.region}:${local.account_id}:key/aws/ssm"
    ]
  }

  # EventBridge Scheduler - create/delete per-session revocation schedules
  # Scoped to zerotrust-jit schedule group only
  statement {
    sid    = "EventBridgeSchedulerJIT"
    effect = "Allow"
    actions = [
      "scheduler:CreateSchedule",
      "scheduler:DeleteSchedule",
      "scheduler:GetSchedule",
    ]
    resources = [
      "arn:aws:scheduler:${local.region}:${local.account_id}:schedule/zerotrust-jit/*"
    ]
  }

  # IAM PassRole - jit-provisioner passes scheduler role when creating schedules
  statement {
    sid     = "PassSchedulerRole"
    effect  = "Allow"
    actions = ["iam:PassRole"]
    resources = [aws_iam_role.scheduler.arn]
    condition {
      test     = "StringEquals"
      variable = "iam:PassedToService"
      values   = ["scheduler.amazonaws.com"]
    }
  }

  # CloudWatch - emit JIT session counters (namespace scoped)
  statement {
    sid     = "CloudWatchMetricsPut"
    effect  = "Allow"
    actions = ["cloudwatch:PutMetricData"]
    resources = ["*"]
    condition {
      test     = "StringEquals"
      variable = "cloudwatch:namespace"
      values   = ["ZeroTrust/JIT"]
    }
  }

  # CloudWatch - read session counters for GET /session-count
  statement {
    sid    = "CloudWatchMetricsRead"
    effect = "Allow"
    actions = [
      "cloudwatch:GetMetricStatistics",
      "cloudwatch:GetMetricData",
    ]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "lambda_permissions" {
  name   = "zerotrust-lambda-permissions"
  role   = aws_iam_role.lambda_execution.id
  policy = data.aws_iam_policy_document.lambda_permissions.json
}

################################################################################
# EventBridge Scheduler Role
# Scoped to invoke jit-revoker Lambda only
################################################################################

data "aws_iam_policy_document" "scheduler_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["scheduler.amazonaws.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "aws:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "scheduler" {
  name               = "zerotrust-scheduler-role"
  assume_role_policy = data.aws_iam_policy_document.scheduler_assume_role.json
  description        = "EventBridge Scheduler - invoke jit-revoker only"

  tags = {
    Name    = "zerotrust-scheduler-role"
    Purpose = "EventBridge Scheduler → jit-revoker invocation"
  }
}

data "aws_iam_policy_document" "scheduler_invoke" {
  statement {
    sid     = "InvokeJITRevokerOnly"
    effect  = "Allow"
    actions = ["lambda:InvokeFunction"]
    resources = [
      "arn:aws:lambda:${local.region}:${local.account_id}:function:${local.fn_revoker}",
      "arn:aws:lambda:${local.region}:${local.account_id}:function:${local.fn_revoker}:*",
    ]
  }
}

resource "aws_iam_role_policy" "scheduler_invoke" {
  name   = "zerotrust-scheduler-invoke-policy"
  role   = aws_iam_role.scheduler.id
  policy = data.aws_iam_policy_document.scheduler_invoke.json
}
