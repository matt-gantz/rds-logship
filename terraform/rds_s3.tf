# IAM Role that RDS will assume to access S3
resource "aws_iam_role" "rds_s3_role" {
  name = "rds-sqlserver-s3-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Principal = {
          Service = "rds.amazonaws.com"
        }
        Action = "sts:AssumeRole"
      },
      {
        Effect = "Allow"
        Principal = {
          AWS = aws_iam_user.s3_backup_user.arn
        }
        Action = "sts:AssumeRole"
      }
    ]
  })

  tags = {
    Name = "rds-sqlserver-s3-role"
  }
}

# IAM Policy allowing RDS SQL Server to perform read/write operations on the demo bucket
resource "aws_iam_role_policy" "rds_s3_policy" {
  name = "rds-sqlserver-s3-policy"
  role = aws_iam_role.rds_s3_role.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:ListBucket",
          "s3:ListObjectsV2",
          "s3:GetBucketLocation",
          "s3:AbortMultipartUpload"
        ]
        Resource = [
          aws_s3_bucket.demo_bucket.arn,
          "${aws_s3_bucket.demo_bucket.arn}/*"
        ]
      }
    ]
  })
}

resource "aws_iam_user" "s3_backup_user" {
  name = "s3_backup_user"

  tags = {
    Name = "s3_backup_user"
  }
}

resource "aws_iam_user_policy" "s3_backup_user_assume_role" {
  name = "s3_backup_user-assume-rds-sqlserver-s3-role"
  user = aws_iam_user.s3_backup_user.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = "sts:AssumeRole"
        Resource = aws_iam_role.rds_s3_role.arn
      }
    ]
  })
}

resource "aws_iam_user_policy" "s3_backup_user_s3_access" {
  name = "s3_backup_user-s3-access"
  user = aws_iam_user.s3_backup_user.name

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:ListBucket",
          "s3:GetBucketLocation"
        ]
        Resource = aws_s3_bucket.demo_bucket.arn
      },
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:PutObject",
          "s3:AbortMultipartUpload"
        ]
        Resource = "${aws_s3_bucket.demo_bucket.arn}/*"
      }
    ]
  })
}

# RDS Option Group to enable SQL Server native backup and restore integration with S3
resource "aws_db_option_group" "sqlserver_option_group" {
  name                 = "rds-sqlserver-s3-option-group"
  engine_name          = "sqlserver-ex"
  major_engine_version = "16.00"

  option {
    option_name = "SQLSERVER_BACKUP_RESTORE"

    option_settings {
      name  = "IAM_ROLE_ARN"
      value = aws_iam_role.rds_s3_role.arn
    }
  }

  tags = {
    Name = "rds-sqlserver-s3-option-group"
  }
}
