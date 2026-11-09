output "rds_endpoint" {
  value       = aws_db_instance.sql_server.endpoint
  description = "The connection endpoint for the RDS SQL Server instance (address:port)"
}

output "rds_address" {
  value       = aws_db_instance.sql_server.address
  description = "The database address (hostname)"
}

output "rds_port" {
  value       = aws_db_instance.sql_server.port
  description = "The database connection port"
}

output "s3_bucket_name" {
  value       = aws_s3_bucket.demo_bucket.id
  description = "The name of the S3 bucket"
}

output "s3_bucket_domain_name" {
  value       = aws_s3_bucket.demo_bucket.bucket_regional_domain_name
  description = "The S3 bucket regional domain name"
}

output "s3_backup_user_name" {
  value       = aws_iam_user.s3_backup_user.name
  description = "The IAM user that can assume the RDS S3 role"
}

output "s3_backup_user_arn" {
  value       = aws_iam_user.s3_backup_user.arn
  description = "The ARN of the IAM user that can assume the RDS S3 role"
}

output "stop_rds_lambda_name" {
  value       = aws_lambda_function.stop_rds_instance.function_name
  description = "The Lambda function that stops the RDS instance"
}

output "rds_insert_logship_lambda_name" {
  value       = aws_lambda_function.rds_insert_logship.function_name
  description = "The Lambda function that inserts SQL Server log records into the utility database"
}

output "rds_insert_logship_ecr_repo" {
  value       = aws_ecr_repository.rds_insert_logship.repository_url
  description = "The ECR repository that stores the insert Lambda image"
}

output "db_restore_username" {
  value       = var.db_restore_username
  description = "The SQL login used by the restore Lambda"
}

output "db_restore_password_parameter_name" {
  value       = aws_ssm_parameter.restore_rds_password.name
  description = "The SSM parameter that stores the restore password"
}
