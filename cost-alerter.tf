variable "cost_alerter_enabled" {
  description = "Enable or disable the cost alerter"
  type        = bool
  default     = true
}

variable "cost_alert_threshold" {
  description = "Cost threshold in USD that triggers an alert"
  type        = number
  default     = 10
}

variable "cost_critical_threshold" {
  description = "Critical cost threshold in USD that triggers nuke warning"
  type        = number
  default     = 50
}

variable "ntfy_topic" {
  description = "ntfy topic name for alerts (will be created at ntfy.sh/<topic>)"
  type        = string
  default     = "aws-cost-alerts"
}

variable "ntfy_server" {
  description = "ntfy server URL (use https://ntfy.sh for public or your own server)"
  type        = string
  default     = "https://ntfy.sh"
}

variable "ntfy_token" {
  description = "Optional ntfy authentication token for private topics"
  type        = string
  default     = ""
  sensitive   = true
}

variable "cost_check_schedule" {
  description = "Schedule expression for cost checks (default: every 6 hours)"
  type        = string
  default     = "rate(6 hours)"
}

variable "enable_auto_nuke" {
  description = "Enable automatic resource cleanup when critical threshold is exceeded (DANGEROUS)"
  type        = bool
  default     = false
}

variable "nuke_dry_run" {
  description = "Run nuke in dry-run mode (only lists resources, doesn't delete)"
  type        = bool
  default     = true
}

variable "send_daily_summary" {
  description = "Send daily cost summary even when under threshold"
  type        = bool
  default     = false
}

# IAM Role

resource "aws_iam_role" "cost_alerter_lambda" {
  count = var.cost_alerter_enabled ? 1 : 0
  name  = "${var.project_name}-cost-alerter-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name        = "${var.project_name}-cost-alerter-role"
    Environment = var.environment
    Project     = "Cost Alerter"
  }
}

# Policy for Cost Explorer access and CloudWatch Logs
resource "aws_iam_role_policy" "cost_alerter_base" {
  count = var.cost_alerter_enabled ? 1 : 0
  name  = "${var.project_name}-cost-alerter-base"
  role  = aws_iam_role.cost_alerter_lambda[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "CostExplorerAccess"
        Effect = "Allow"
        Action = [
          "ce:GetCostAndUsage",
          "ce:GetCostForecast",
          "ce:GetDimensionValues"
        ]
        Resource = "*"
      },
      {
        Sid    = "CloudWatchLogs"
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      },
      {
        Sid    = "DescribeResources"
        Effect = "Allow"
        Action = [
          "ec2:DescribeInstances",
          "ec2:DescribeNatGateways",
          "rds:DescribeDBInstances",
          "lambda:ListFunctions",
          "s3:ListAllMyBuckets"
        ]
        Resource = "*"
      }
    ]
  })
}

# Additional policy for resource nuke
resource "aws_iam_role_policy" "cost_alerter_nuke" {
  count = var.cost_alerter_enabled && var.enable_auto_nuke ? 1 : 0
  name  = "${var.project_name}-cost-alerter-nuke"
  role  = aws_iam_role.cost_alerter_lambda[0].id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "EC2Management"
        Effect = "Allow"
        Action = [
          "ec2:StopInstances",
          "ec2:TerminateInstances",
          "ec2:DeleteNatGateway"
        ]
        Resource = "*"
        Condition = {
          StringEquals = {
            "aws:ResourceTag/CanNuke" = "true"
          }
        }
      },
      {
        Sid    = "EC2ManagementUntagged"
        Effect = "Allow"
        Action = [
          "ec2:StopInstances",
          "ec2:DeleteNatGateway"
        ]
        Resource = "*"
      },
      {
        Sid    = "RDSManagement"
        Effect = "Allow"
        Action = [
          "rds:StopDBInstance"
        ]
        Resource = "*"
      }
    ]
  })
}

# Lambda Function

data "archive_file" "cost_alerter_zip" {
  count       = var.cost_alerter_enabled ? 1 : 0
  type        = "zip"
  source_file = "${path.module}/lambda/cost_alerter.py"
  output_path = "${path.module}/lambda/cost_alerter.zip"
}

resource "aws_lambda_function" "cost_alerter" {
  count            = var.cost_alerter_enabled ? 1 : 0
  filename         = data.archive_file.cost_alerter_zip[0].output_path
  function_name    = "${var.project_name}-cost-alerter"
  role             = aws_iam_role.cost_alerter_lambda[0].arn
  handler          = "cost_alerter.lambda_handler"
  source_code_hash = data.archive_file.cost_alerter_zip[0].output_base64sha256
  runtime          = "python3.11"
  timeout          = 60
  memory_size      = 256

  environment {
    variables = {
      ALERT_THRESHOLD    = tostring(var.cost_alert_threshold)
      CRITICAL_THRESHOLD = tostring(var.cost_critical_threshold)
      NTFY_TOPIC         = var.ntfy_topic
      NTFY_SERVER        = var.ntfy_server
      NTFY_TOKEN         = var.ntfy_token
      ENABLE_AUTO_NUKE   = tostring(var.enable_auto_nuke)
      NUKE_DRY_RUN       = tostring(var.nuke_dry_run)
      SEND_DAILY_SUMMARY = tostring(var.send_daily_summary)
    }
  }

  tags = {
    Name        = "${var.project_name}-cost-alerter"
    Environment = var.environment
    Project     = "Cost Alerter"
  }
}

# CloudWatch Log Group with retention
resource "aws_cloudwatch_log_group" "cost_alerter" {
  count             = var.cost_alerter_enabled ? 1 : 0
  name              = "/aws/lambda/${var.project_name}-cost-alerter"
  retention_in_days = 14

  tags = {
    Name        = "${var.project_name}-cost-alerter-logs"
    Environment = var.environment
  }
}

# Event Bridge

resource "aws_cloudwatch_event_rule" "cost_alerter_schedule" {
  count               = var.cost_alerter_enabled ? 1 : 0
  name                = "${var.project_name}-cost-alerter-schedule"
  description         = "Triggers cost alerter Lambda on schedule"
  schedule_expression = var.cost_check_schedule

  tags = {
    Name        = "${var.project_name}-cost-alerter-schedule"
    Environment = var.environment
  }
}

resource "aws_cloudwatch_event_target" "cost_alerter" {
  count     = var.cost_alerter_enabled ? 1 : 0
  rule      = aws_cloudwatch_event_rule.cost_alerter_schedule[0].name
  target_id = "CostAlerterLambda"
  arn       = aws_lambda_function.cost_alerter[0].arn
}

resource "aws_lambda_permission" "eventbridge_cost_alerter" {
  count         = var.cost_alerter_enabled ? 1 : 0
  statement_id  = "AllowExecutionFromEventBridge"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cost_alerter[0].function_name
  principal     = "events.amazonaws.com"
  source_arn    = aws_cloudwatch_event_rule.cost_alerter_schedule[0].arn
}

# SNS topic

resource "aws_sns_topic" "cost_alerts" {
  count = var.cost_alerter_enabled ? 1 : 0
  name  = "${var.project_name}-cost-alerts"

  tags = {
    Name        = "${var.project_name}-cost-alerts"
    Environment = var.environment
  }
}

# SNS Topic Policy
resource "aws_sns_topic_policy" "cost_alerts" {
  count = var.cost_alerter_enabled ? 1 : 0
  arn   = aws_sns_topic.cost_alerts[0].arn
  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowBudgetPublish"
        Effect = "Allow"
        Principal = {
          Service = "budgets.amazonaws.com"
        }
        Action   = "SNS:Publish"
        Resource = aws_sns_topic.cost_alerts[0].arn
      }
    ]
  })
}

# Lambda subscription to SNS for real-time budget alerts
resource "aws_sns_topic_subscription" "cost_alerter_lambda" {
  count     = var.cost_alerter_enabled ? 1 : 0
  topic_arn = aws_sns_topic.cost_alerts[0].arn
  protocol  = "lambda"
  endpoint  = aws_lambda_function.cost_alerter[0].arn
}

resource "aws_lambda_permission" "sns_cost_alerter" {
  count         = var.cost_alerter_enabled ? 1 : 0
  statement_id  = "AllowExecutionFromSNS"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.cost_alerter[0].function_name
  principal     = "sns.amazonaws.com"
  source_arn    = aws_sns_topic.cost_alerts[0].arn
}

# AWS budgeting

resource "aws_budgets_budget" "monthly_cost" {
  count             = var.cost_alerter_enabled ? 1 : 0
  name              = "${var.project_name}-monthly-budget"
  budget_type       = "COST"
  limit_amount      = tostring(var.cost_critical_threshold)
  limit_unit        = "USD"
  time_unit         = "MONTHLY"
  time_period_start = "2024-01-01_00:00"

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 80
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.cost_alerts[0].arn]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "ACTUAL"
    subscriber_sns_topic_arns = [aws_sns_topic.cost_alerts[0].arn]
  }

  notification {
    comparison_operator       = "GREATER_THAN"
    threshold                 = 100
    threshold_type            = "PERCENTAGE"
    notification_type         = "FORECASTED"
    subscriber_sns_topic_arns = [aws_sns_topic.cost_alerts[0].arn]
  }

  tags = {
    Name        = "${var.project_name}-monthly-budget"
    Environment = var.environment
  }
}

# Outputs

output "cost_alerter_lambda_arn" {
  description = "ARN of the cost alerter Lambda function"
  value       = var.cost_alerter_enabled ? aws_lambda_function.cost_alerter[0].arn : null
}

output "cost_alerter_lambda_name" {
  description = "Name of the cost alerter Lambda function"
  value       = var.cost_alerter_enabled ? aws_lambda_function.cost_alerter[0].function_name : null
}

output "cost_alerts_sns_topic_arn" {
  description = "ARN of the SNS topic for cost alerts"
  value       = var.cost_alerter_enabled ? aws_sns_topic.cost_alerts[0].arn : null
}

output "ntfy_subscription_url" {
  description = "URL to subscribe to ntfy alerts"
  value       = var.cost_alerter_enabled ? "${var.ntfy_server}/${var.ntfy_topic}" : null
}

output "cost_alerter_schedule" {
  description = "Schedule expression for cost checks"
  value       = var.cost_alerter_enabled ? var.cost_check_schedule : null
}

output "cost_alerter_invoke_command" {
  description = "AWS CLI command to manually invoke the cost alerter"
  value       = var.cost_alerter_enabled ? "aws lambda invoke --function-name ${aws_lambda_function.cost_alerter[0].function_name} --log-type Tail output.json" : null
}
