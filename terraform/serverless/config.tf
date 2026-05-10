################################################################################
# config.tf
# AWS Config recorder and managed compliance rules
# Phase 2 + 2.5 — Serverless stack
#
# Rules (3):
#   cloudtrail-enabled                          — CloudTrail must be active
#   lambda-function-public-access-prohibited    — Lambda functions not public
#   s3-bucket-ssl-requests-only                 — S3 buckets enforce SSL
#
# Cost: ~$0.003 per config item recorded — approximately $0.05/month
# Config recorder captures resource changes continuously
################################################################################

################################################################################
# IAM Role for AWS Config
################################################################################

data "aws_iam_policy_document" "config_assume_role" {
  statement {
    effect = "Allow"
    principals {
      type        = "Service"
      identifiers = ["config.amazonaws.com"]
    }
    actions = ["sts:AssumeRole"]
    condition {
      test     = "StringEquals"
      variable = "AWS:SourceAccount"
      values   = [local.account_id]
    }
  }
}

resource "aws_iam_role" "config" {
  name               = "zerotrust-config-role"
  assume_role_policy = data.aws_iam_policy_document.config_assume_role.json

  tags = {
    Name    = "zerotrust-config-role"
    Purpose = "AWS Config service role"
  }
}

resource "aws_iam_role_policy_attachment" "config_managed" {
  role       = aws_iam_role.config.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWS_ConfigRole"
}

resource "aws_iam_role_policy" "config_s3" {
  name = "zerotrust-config-s3-policy"
  role = aws_iam_role.config.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetBucketAcl",
          "s3:PutObject"
        ]
        Resource = [
          "arn:aws:s3:::aws-config-zerotrust-${local.account_id}",
          "arn:aws:s3:::aws-config-zerotrust-${local.account_id}/*"
        ]
      }
    ]
  })
}

################################################################################
# Config Recorder
################################################################################

resource "aws_config_configuration_recorder" "main" {
  name     = "zerotrust-config-recorder"
  role_arn = aws_iam_role.config.arn

  recording_group {
    all_supported                 = false
    include_global_resource_types = false

    # Record only resources relevant to this project
    resource_types = [
      "AWS::Lambda::Function",
      "AWS::S3::Bucket",
      "AWS::ApiGateway::RestApi",
      "AWS::Cognito::UserPool",
      "AWS::IAM::Role",
      "AWS::CloudWatch::Alarm"
    ]
  }
}

################################################################################
# Delivery Channel
################################################################################

resource "aws_config_delivery_channel" "main" {
  name           = "zerotrust-config-delivery"
  s3_bucket_name = aws_s3_bucket.config_logs.bucket

  snapshot_delivery_properties {
    delivery_frequency = "TwentyFour_Hours"
  }

  depends_on = [aws_config_configuration_recorder.main]
}

################################################################################
# Start Recorder
################################################################################

resource "aws_config_configuration_recorder_status" "main" {
  name       = aws_config_configuration_recorder.main.name
  is_enabled = true

  depends_on = [aws_config_delivery_channel.main]
}

################################################################################
# Config Rules
################################################################################

# Rule 1 — CloudTrail must be enabled
resource "aws_config_config_rule" "cloudtrail_enabled" {
  name        = "zerotrust-cloudtrail-enabled"
  description = "Checks that CloudTrail is enabled in this account"

  source {
    owner             = "AWS"
    source_identifier = "CLOUD_TRAIL_ENABLED"
  }

  depends_on = [aws_config_configuration_recorder_status.main]

  tags = {
    Name = "zerotrust-cloudtrail-enabled"
  }
}

# Rule 2 — Lambda functions must not have public access
resource "aws_config_config_rule" "lambda_public_access" {
  name        = "zerotrust-lambda-no-public-access"
  description = "Checks that Lambda functions do not allow public access"

  source {
    owner             = "AWS"
    source_identifier = "LAMBDA_FUNCTION_PUBLIC_ACCESS_PROHIBITED"
  }

  scope {
    compliance_resource_types = ["AWS::Lambda::Function"]
  }

  depends_on = [aws_config_configuration_recorder_status.main]

  tags = {
    Name = "zerotrust-lambda-no-public-access"
  }
}

# Rule 3 — S3 buckets must enforce SSL requests only
resource "aws_config_config_rule" "s3_ssl_only" {
  name        = "zerotrust-s3-ssl-requests-only"
  description = "Checks that S3 buckets have policies requiring SSL requests"

  source {
    owner             = "AWS"
    source_identifier = "S3_BUCKET_SSL_REQUESTS_ONLY"
  }

  scope {
    compliance_resource_types = ["AWS::S3::Bucket"]
  }

  depends_on = [aws_config_configuration_recorder_status.main]

  tags = {
    Name = "zerotrust-s3-ssl-requests-only"
  }
}
