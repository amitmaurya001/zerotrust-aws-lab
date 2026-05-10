################################################################################
# cloudwatch.tf
# CloudWatch log groups, alarms, SNS topic, session counter metrics
# Phase 2 + 2.5 — Serverless stack
#
# Session counter uses CloudWatch metric math — no DynamoDB needed
# Lambda emits ZeroTrust/JIT/UserCreated and UserDeleted metrics
# GET /session-count reads these via session-checker Lambda
################################################################################

################################################################################
# Log Groups
################################################################################

resource "aws_cloudwatch_log_group" "lambda_provisioner" {
  name              = "/aws/lambda/${local.fn_provisioner}"
  retention_in_days = var.log_retention_days

  tags = {
    Name    = "/aws/lambda/${local.fn_provisioner}"
    Purpose = "JIT provisioner Lambda logs"
  }
}

resource "aws_cloudwatch_log_group" "lambda_revoker" {
  name              = "/aws/lambda/${local.fn_revoker}"
  retention_in_days = var.log_retention_days

  tags = {
    Name    = "/aws/lambda/${local.fn_revoker}"
    Purpose = "JIT revoker Lambda logs"
  }
}

resource "aws_cloudwatch_log_group" "lambda_checker" {
  name              = "/aws/lambda/${local.fn_checker}"
  retention_in_days = var.log_retention_days

  tags = {
    Name    = "/aws/lambda/${local.fn_checker}"
    Purpose = "Session checker Lambda logs"
  }
}

################################################################################
# SNS Topic — alert notifications
################################################################################

resource "aws_sns_topic" "alerts" {
  name         = "zerotrust-alerts"
  display_name = "Zero Trust Lab Alerts"

  tags = {
    Name    = "zerotrust-alerts"
    Purpose = "CloudWatch alarm notifications"
  }
}

resource "aws_sns_topic_subscription" "email" {
  topic_arn = aws_sns_topic.alerts.arn
  protocol  = "email"
  endpoint  = var.alert_email
}

################################################################################
# CloudWatch Alarms
################################################################################

# Alarm 1 — Lambda error rate across all three functions
resource "aws_cloudwatch_metric_alarm" "lambda_errors" {
  alarm_name          = "zerotrust-lambda-errors"
  alarm_description   = "Lambda error rate exceeded threshold across JIT functions"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  threshold           = 5
  treat_missing_data  = "notBreaching"

  metric_query {
    id          = "provisioner_errors"
    return_data = false
    metric {
      metric_name = "Errors"
      namespace   = "AWS/Lambda"
      period      = 300
      stat        = "Sum"
      dimensions = {
        FunctionName = local.fn_provisioner
      }
    }
  }

  metric_query {
    id          = "revoker_errors"
    return_data = false
    metric {
      metric_name = "Errors"
      namespace   = "AWS/Lambda"
      period      = 300
      stat        = "Sum"
      dimensions = {
        FunctionName = local.fn_revoker
      }
    }
  }

  metric_query {
    id          = "checker_errors"
    return_data = false
    metric {
      metric_name = "Errors"
      namespace   = "AWS/Lambda"
      period      = 300
      stat        = "Sum"
      dimensions = {
        FunctionName = local.fn_checker
      }
    }
  }

  metric_query {
    id          = "total_errors"
    return_data = true
    expression  = "provisioner_errors + revoker_errors + checker_errors"
    label       = "Total Lambda Errors"
  }

  alarm_actions = [aws_sns_topic.alerts.arn]
  ok_actions    = [aws_sns_topic.alerts.arn]

  tags = {
    Name = "zerotrust-lambda-errors"
  }
}

# Alarm 2 — API Gateway throttle rate
resource "aws_cloudwatch_metric_alarm" "api_throttle" {
  alarm_name          = "zerotrust-api-throttle"
  alarm_description   = "API Gateway throttle count exceeded — possible abuse"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 1
  metric_name         = "4xx"
  namespace           = "AWS/ApiGateway"
  period              = 300
  statistic           = "Sum"
  threshold           = 20
  treat_missing_data  = "notBreaching"

  dimensions = {
    ApiId = aws_apigatewayv2_api.main.id
  }

  alarm_actions = [aws_sns_topic.alerts.arn]

  tags = {
    Name = "zerotrust-api-throttle"
  }
}

# Alarm 3 — JIT provisioning failures (custom metric)
resource "aws_cloudwatch_metric_alarm" "jit_failures" {
  alarm_name          = "zerotrust-jit-provisioning-failure"
  alarm_description   = "JIT provisioning failures exceeded threshold — Okta API issue likely"
  comparison_operator = "GreaterThanThreshold"
  evaluation_periods  = 2
  metric_name         = "ProvisioningFailure"
  namespace           = "ZeroTrust/JIT"
  period              = 600
  statistic           = "Sum"
  threshold           = 3
  treat_missing_data  = "notBreaching"

  alarm_actions = [aws_sns_topic.alerts.arn]

  tags = {
    Name = "zerotrust-jit-provisioning-failure"
  }
}

################################################################################
# CloudWatch Dashboard — optional but useful for demo screenshots
################################################################################

resource "aws_cloudwatch_dashboard" "zerotrust" {
  dashboard_name = "ZeroTrust-JIT-Demo"

  dashboard_body = jsonencode({
    widgets = [
      {
        type   = "metric"
        x      = 0
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "JIT Sessions — Provisioned vs Deleted"
          period = 3600
          stat   = "Sum"
          metrics = [
            ["ZeroTrust/JIT", "UserCreated", { label = "Provisioned", color = "#00d4ff" }],
            ["ZeroTrust/JIT", "UserDeleted", { label = "Auto-deleted", color = "#22c55e" }]
          ]
          view    = "timeSeries"
          stacked = false
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 0
        width  = 12
        height = 6
        properties = {
          title  = "Lambda Errors"
          period = 300
          stat   = "Sum"
          metrics = [
            ["AWS/Lambda", "Errors", "FunctionName", local.fn_provisioner],
            ["AWS/Lambda", "Errors", "FunctionName", local.fn_revoker],
            ["AWS/Lambda", "Errors", "FunctionName", local.fn_checker]
          ]
          view = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 0
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "API Gateway Requests"
          period = 300
          stat   = "Sum"
          metrics = [
            ["AWS/ApiGateway", "Count", "ApiId", aws_apigatewayv2_api.main.id, { label = "Total Requests" }],
            ["AWS/ApiGateway", "4xx",   "ApiId", aws_apigatewayv2_api.main.id, { label = "4xx Errors" }],
            ["AWS/ApiGateway", "5xx",   "ApiId", aws_apigatewayv2_api.main.id, { label = "5xx Errors" }]
          ]
          view = "timeSeries"
        }
      },
      {
        type   = "metric"
        x      = 12
        y      = 6
        width  = 12
        height = 6
        properties = {
          title  = "Lambda Duration (ms)"
          period = 300
          stat   = "Average"
          metrics = [
            ["AWS/Lambda", "Duration", "FunctionName", local.fn_provisioner],
            ["AWS/Lambda", "Duration", "FunctionName", local.fn_revoker],
            ["AWS/Lambda", "Duration", "FunctionName", local.fn_checker]
          ]
          view = "timeSeries"
        }
      }
    ]
  })
}
