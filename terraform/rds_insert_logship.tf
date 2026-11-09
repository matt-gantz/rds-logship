locals {
  rds_insert_lambda_name = "rds-logship-rds-insert-logship"
  rds_insert_image_tag = substr(
    sha256(join("", [
      filesha256("${path.module}/lambda/rds_insert_logship/app.py"),
      filesha256("${path.module}/lambda/rds_insert_logship/Dockerfile"),
      filesha256("${path.module}/scripts/build_restore_rds_image.py"),
    ])),
    0,
    16
  )
  rds_insert_log_prefix   = "backups/LSDemo/Log/"
  rds_insert_database     = "Utility"
  rds_insert_target_db    = "LSDemo"
  rds_insert_s3_base_arn  = "${aws_s3_bucket.demo_bucket.arn}/backups/LSDemo/Log"
  rds_insert_sql_password = coalesce(var.db_restore_password, var.db_password)
}

resource "aws_ssm_parameter" "restore_rds_password" {
  name        = var.db_restore_password_parameter_name
  description = "Password for the log_ship_restore_user SQL login"
  type        = "SecureString"
  key_id      = data.aws_kms_key.ssm.arn
  value       = local.rds_insert_sql_password
  overwrite   = true

  lifecycle {
    ignore_changes = [value]
  }

  tags = {
    Name = "log_ship_restore_user password"
  }
}

resource "aws_ecr_repository" "rds_insert_logship" {
  name                 = "rds-logship-rds-insert-logship"
  image_tag_mutability = "MUTABLE"
  force_delete         = true

  image_scanning_configuration {
    scan_on_push = false
  }

  tags = {
    Name = "rds-logship-rds-insert-logship"
  }
}

resource "null_resource" "rds_insert_image" {
  triggers = {
    source_hash = local.rds_insert_image_tag
  }

  provisioner "local-exec" {
    command = "python ${path.module}/scripts/build_restore_rds_image.py"

    environment = {
      IMAGE_REPOSITORY_URL = aws_ecr_repository.rds_insert_logship.repository_url
      IMAGE_TAG            = local.rds_insert_image_tag
      AWS_REGION           = var.aws_region
      DOCKERFILE_DIR       = abspath("${path.module}/lambda/rds_insert_logship")
    }
  }
}

resource "aws_iam_role" "rds_insert_lambda_role" {
  name = "rds-logship-rds-insert-lambda-role"

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
    Name = "rds-logship-rds-insert-lambda-role"
  }
}

resource "aws_iam_role_policy_attachment" "rds_insert_lambda_basic_execution" {
  role       = aws_iam_role.rds_insert_lambda_role.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "rds_insert_lambda_s3_access" {
  name = "rds-logship-rds-insert-lambda-s3-access"
  role = aws_iam_role.rds_insert_lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket"
        ]
        Resource = aws_s3_bucket.demo_bucket.arn
        Condition = {
          StringLike = {
            "s3:prefix" = [
              local.rds_insert_log_prefix,
              "${local.rds_insert_log_prefix}*"
            ]
          }
        }
      }
    ]
  })
}

resource "aws_iam_role_policy" "rds_insert_lambda_ssm_access" {
  name = "rds-logship-rds-insert-lambda-ssm-access"
  role = aws_iam_role.rds_insert_lambda_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "ssm:GetParameter"
        ]
        Resource = aws_ssm_parameter.restore_rds_password.arn
      },
      {
        Effect = "Allow"
        Action = [
          "kms:Decrypt"
        ]
        Resource = data.aws_kms_key.ssm.arn
      }
    ]
  })
}

resource "aws_lambda_function" "rds_insert_logship" {
  function_name = local.rds_insert_lambda_name
  role          = aws_iam_role.rds_insert_lambda_role.arn
  package_type  = "Image"
  image_uri     = "${aws_ecr_repository.rds_insert_logship.repository_url}:${local.rds_insert_image_tag}"
  timeout       = 900
  memory_size   = 256

  environment {
    variables = {
      LOG_BUCKET_NAME                    = aws_s3_bucket.demo_bucket.bucket
      LOG_PREFIX                         = local.rds_insert_log_prefix
      RESTORE_DB_NAME                    = local.rds_insert_target_db
      RESTORE_S3_BASE_ARN                = local.rds_insert_s3_base_arn
      SQL_HOST                           = aws_db_instance.sql_server.address
      SQL_PORT                           = tostring(aws_db_instance.sql_server.port)
      SQL_USERNAME                       = var.db_restore_username
      DB_RESTORE_PASSWORD_PARAMETER_NAME = aws_ssm_parameter.restore_rds_password.name
      UTILITY_DATABASE                   = local.rds_insert_database
    }
  }

  depends_on = [
    null_resource.rds_insert_image
  ]

  tags = {
    Name = local.rds_insert_lambda_name
  }
}

resource "aws_cloudwatch_log_group" "rds_insert_logship" {
  name              = "/aws/lambda/${aws_lambda_function.rds_insert_logship.function_name}"
  retention_in_days = 14
}
