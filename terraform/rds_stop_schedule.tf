locals {
  stop_rds_lambda_name   = "rds-logship-stop-rds"
}

data "archive_file" "stop_rds_lambda" {
  type        = "zip"
  source_file = "${path.module}/lambda/stop_rds_instance.py"
  output_path = "${path.module}/.terraform/stop-rds-instance.zip"
}

resource "aws_iam_role" "stop_rds_lambda_role" {
  name = "rds-logship-stop-rds-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "rds-logship-stop-rds-lambda-role"
  }
}

resource "aws_iam_role_policy_attachment" "stop_rds_lambda_basic_execution" {
  role       = aws_iam_role.stop_rds_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "stop_rds_lambda_rds_access" {
  name = "rds-logship-stop-rds-lambda-rds-access"
  role = aws_iam_role.stop_rds_lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "rds:DescribeDBInstances",
          "rds:StopDBInstance"
        ]
        Resource = "*"
      }
    ]
  })
}

resource "aws_lambda_function" "stop_rds_instance" {
  function_name    = local.stop_rds_lambda_name
  role             = aws_iam_role.stop_rds_lambda_role.arn
  handler          = "stop_rds_instance.handler"
  runtime          = "python3.12"
  filename         = data.archive_file.stop_rds_lambda.output_path
  source_code_hash = data.archive_file.stop_rds_lambda.output_base64sha256
  timeout          = 30
  memory_size      = 128

  environment {
    variables = {
      DB_INSTANCE_IDENTIFIER = aws_db_instance.sql_server.identifier
    }
  }

  tags = {
    Name = local.stop_rds_lambda_name
  }
}

resource "aws_cloudwatch_log_group" "stop_rds_lambda" {
  name              = "/aws/lambda/${aws_lambda_function.stop_rds_instance.function_name}"
  retention_in_days = 14
}
