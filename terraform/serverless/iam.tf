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

################################################################################
# GitHub Actions OIDC - Serverless Deploy Role
# Locked to repo amitmaurya001/zerotrust-aws-lab + environment:production
################################################################################

data "aws_iam_policy_document" "github_actions_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRoleWithWebIdentity"]
    principals {
      type        = "Federated"
      identifiers = ["arn:aws:iam::${local.account_id}:oidc-provider/token.actions.githubusercontent.com"]
    }
    condition {
      test     = "StringEquals"
      variable = "token.actions.githubusercontent.com:aud"
      values   = ["sts.amazonaws.com"]
    }
    condition {
      test     = "StringLike"
      variable = "token.actions.githubusercontent.com:sub"
      values   = ["repo:amitmaurya001/zerotrust-aws-lab:environment:production"]
    }
  }
}

resource "aws_iam_role" "github_actions_serverless" {
  name                 = "zerotrust-serverless-deploy-role"
  assume_role_policy   = data.aws_iam_policy_document.github_actions_assume_role.json
  description          = "GitHub Actions OIDC deploy role - serverless stack only"
  max_session_duration = 3600

  tags = {
    Name    = "zerotrust-serverless-deploy-role"
    Purpose = "GitHub Actions OIDC - serverless Terraform + S3 sync"
  }
}

data "aws_iam_policy_document" "github_actions_serverless_permissions" {

  # S3 - state bucket + ZTNA website buckets + config logs
  statement {
    sid    = "S3TerraformState"
    effect = "Allow"
    actions = [
      "s3:GetObject", "s3:PutObject", "s3:DeleteObject",
      "s3:ListBucket", "s3:GetBucketVersioning", "s3:PutBucketVersioning",
    ]
    resources = [
      "arn:aws:s3:::zerotrust-tf-*",
      "arn:aws:s3:::zerotrust-tf-*/*",
      "arn:aws:s3:::webapp.${var.domain}",
      "arn:aws:s3:::webapp.${var.domain}/*",
      "arn:aws:s3:::private.${var.domain}",
      "arn:aws:s3:::private.${var.domain}/*",
      "arn:aws:s3:::aws-config-zerotrust-*",
      "arn:aws:s3:::aws-config-zerotrust-*/*",
    ]
  }

  statement {
    sid    = "S3BucketManagement"
    effect = "Allow"
    actions = [
      "s3:CreateBucket", "s3:DeleteBucket",
      "s3:GetBucketPolicy", "s3:PutBucketPolicy", "s3:DeleteBucketPolicy",
      "s3:GetBucketWebsite", "s3:PutBucketWebsite", "s3:DeleteBucketWebsite",
      "s3:GetBucketPublicAccessBlock", "s3:PutBucketPublicAccessBlock",
      "s3:GetEncryptionConfiguration", "s3:PutEncryptionConfiguration",
      "s3:GetLifecycleConfiguration", "s3:PutLifecycleConfiguration",
      "s3:GetBucketTagging", "s3:PutBucketTagging",
      "s3:GetBucketAcl", "s3:GetBucketLogging",
    ]
    resources = [
      "arn:aws:s3:::webapp.${var.domain}",
      "arn:aws:s3:::private.${var.domain}",
      "arn:aws:s3:::aws-config-zerotrust-*",
      "arn:aws:s3:::zerotrust-tf-*",
    ]
  }

  # Lambda - 3 ZTNA functions only
  statement {
    sid    = "LambdaManagement"
    effect = "Allow"
    actions = [
      "lambda:CreateFunction", "lambda:UpdateFunctionCode",
      "lambda:UpdateFunctionConfiguration", "lambda:DeleteFunction",
      "lambda:GetFunction", "lambda:GetFunctionConfiguration",
      "lambda:AddPermission", "lambda:RemovePermission", "lambda:GetPolicy",
      "lambda:TagResource", "lambda:UntagResource", "lambda:ListTags",
      "lambda:PublishVersion", "lambda:ListVersionsByFunction",
    ]
    resources = [
      "arn:aws:lambda:${var.aws_region}:*:function:jit-provisioner",
      "arn:aws:lambda:${var.aws_region}:*:function:jit-revoker",
      "arn:aws:lambda:${var.aws_region}:*:function:session-checker",
    ]
  }

  # API Gateway HTTP API
  statement {
    sid    = "APIGatewayManagement"
    effect = "Allow"
    actions = [
      "apigateway:GET", "apigateway:POST", "apigateway:PUT",
      "apigateway:PATCH", "apigateway:DELETE", "apigateway:TagResource",
    ]
    resources = [
      "arn:aws:apigateway:${var.aws_region}::/apis",
      "arn:aws:apigateway:${var.aws_region}::/apis/*",
    ]
  }

  # Cognito
  statement {
    sid    = "CognitoManagement"
    effect = "Allow"
    actions = [
      "cognito-idp:CreateUserPool", "cognito-idp:DeleteUserPool",
      "cognito-idp:DescribeUserPool", "cognito-idp:UpdateUserPool",
      "cognito-idp:CreateUserPoolClient", "cognito-idp:DeleteUserPoolClient",
      "cognito-idp:DescribeUserPoolClient", "cognito-idp:UpdateUserPoolClient",
      "cognito-idp:CreateUserPoolDomain", "cognito-idp:DeleteUserPoolDomain",
      "cognito-idp:DescribeUserPoolDomain",
      "cognito-idp:ListTagsForResource", "cognito-idp:TagResource", "cognito-idp:UntagResource",
    ]
    resources = ["*"]
  }

  # EventBridge Scheduler - schedule group management
  statement {
    sid    = "EventBridgeScheduler"
    effect = "Allow"
    actions = [
      "scheduler:CreateScheduleGroup", "scheduler:DeleteScheduleGroup",
      "scheduler:GetScheduleGroup", "scheduler:ListScheduleGroups",
      "scheduler:TagResource", "scheduler:UntagResource", "scheduler:ListTagsForResource",
    ]
    resources = [
      "arn:aws:scheduler:${var.aws_region}:*:schedule-group/zerotrust-jit",
    ]
  }

  # IAM - zerotrust-* roles only
  statement {
    sid    = "IAMZeroTrustRoles"
    effect = "Allow"
    actions = [
      "iam:CreateRole", "iam:DeleteRole", "iam:GetRole", "iam:UpdateRole",
      "iam:PassRole",
      "iam:AttachRolePolicy", "iam:DetachRolePolicy",
      "iam:PutRolePolicy", "iam:DeleteRolePolicy",
      "iam:GetRolePolicy", "iam:ListRolePolicies", "iam:ListAttachedRolePolicies",
      "iam:TagRole", "iam:UntagRole",
    ]
    resources = [
      "arn:aws:iam::*:role/zerotrust-*",
      "arn:aws:iam::*:role/aws-service-role/config.amazonaws.com/*",
    ]
  }

  # IAM - read OIDC provider (created manually as pre-req)
  statement {
    sid     = "IAMOIDCRead"
    effect  = "Allow"
    actions = ["iam:GetOpenIDConnectProvider"]
    resources = [
      "arn:aws:iam::*:oidc-provider/token.actions.githubusercontent.com"
    ]
  }

  # IAM - service linked role for AWS Config
  statement {
    sid     = "IAMServiceLinkedRole"
    effect  = "Allow"
    actions = ["iam:CreateServiceLinkedRole"]
    resources = [
      "arn:aws:iam::*:role/aws-service-role/config.amazonaws.com/*"
    ]
    condition {
      test     = "StringLike"
      variable = "iam:AWSServiceName"
      values   = ["config.amazonaws.com"]
    }
  }

  # IAM - attach managed policies to roles
  statement {
    sid     = "IAMManagedPolicyAttach"
    effect  = "Allow"
    actions = ["iam:AttachRolePolicy", "iam:DetachRolePolicy"]
    resources = ["arn:aws:iam::*:role/zerotrust-*"]
    condition {
      test     = "ArnLike"
      variable = "iam:PolicyARN"
      values   = [
        "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole",
        "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole",
      ]
    }
  }

  # CloudWatch - log groups, alarms, dashboard
  statement {
    sid    = "CloudWatchManagement"
    effect = "Allow"
    actions = [
      "logs:CreateLogGroup", "logs:DeleteLogGroup",
      "logs:DescribeLogGroups", "logs:PutRetentionPolicy",
      "logs:TagLogGroup", "logs:ListTagsLogGroup",
      "logs:ListTagsForResource",
      "cloudwatch:PutMetricAlarm", "cloudwatch:DeleteAlarms", "cloudwatch:DescribeAlarms",
      "cloudwatch:PutDashboard", "cloudwatch:DeleteDashboards", "cloudwatch:GetDashboard",
      "cloudwatch:TagResource", "cloudwatch:ListTagsForResource",
    ]
    resources = ["*"]
  }

  # SNS - alerts topic
  statement {
    sid    = "SNSManagement"
    effect = "Allow"
    actions = [
      "sns:CreateTopic", "sns:DeleteTopic",
      "sns:GetTopicAttributes", "sns:SetTopicAttributes",
      "sns:Subscribe", "sns:Unsubscribe", "sns:ListSubscriptionsByTopic",
      "sns:GetSubscriptionAttributes",
      "sns:TagResource", "sns:ListTagsForResource",
    ]
    resources = ["arn:aws:sns:${var.aws_region}:*:zerotrust-alerts"]
  }

  # AWS Config
  statement {
    sid    = "ConfigManagement"
    effect = "Allow"
    actions = [
      "config:PutConfigurationRecorder", "config:DeleteConfigurationRecorder",
      "config:DescribeConfigurationRecorders", "config:DescribeConfigurationRecorderStatus",
      "config:StartConfigurationRecorder", "config:StopConfigurationRecorder",
      "config:PutDeliveryChannel", "config:DeleteDeliveryChannel", "config:DescribeDeliveryChannels",
      "config:PutConfigRule", "config:DeleteConfigRule", "config:DescribeConfigRules",
      "config:TagResource",
    ]
    resources = ["*"]
  }

  # SSM - read params for plan/apply validation
  statement {
    sid     = "SSMReadZeroTrustParams"
    effect  = "Allow"
    actions = ["ssm:GetParameter", "ssm:GetParameters", "ssm:DescribeParameters"]
    resources = [
      "arn:aws:ssm:${var.aws_region}:*:parameter/zerotrust/*"
    ]
  }

  # STS - get caller identity
  statement {
    sid       = "STSGetCallerIdentity"
    effect    = "Allow"
    actions   = ["sts:GetCallerIdentity"]
    resources = ["*"]
  }
}

resource "aws_iam_role_policy" "github_actions_serverless_permissions" {
  name   = "zerotrust-serverless-deploy-policy"
  role   = aws_iam_role.github_actions_serverless.id
  policy = data.aws_iam_policy_document.github_actions_serverless_permissions.json
}
