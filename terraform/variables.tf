variable "aws_region" {
  type        = string
  description = "The AWS region to deploy resources in"
  default     = "us-east-1"
}

variable "db_admin_username" {
  type        = string
  description = "Administrator username for the RDS SQL Server instance"
  default     = "admin"
}

variable "db_password" {
  type        = string
  description = "Administrator password for the RDS SQL Server instance"
  sensitive   = true
}

variable "db_restore_username" {
  type        = string
  description = "SQL login used by the restore Lambda"
  default     = "log_ship_restore_user"
}

variable "db_restore_password" {
  type        = string
  description = "Password for the SQL login used by the restore Lambda"
  sensitive   = true
  default     = null
}

variable "db_restore_password_parameter_name" {
  type        = string
  description = "SSM parameter name that stores the restore login password"
  default     = "/rds-logship/log-ship-restore-user-password"
}

variable "allowed_cidr_blocks" {
  type        = list(string)
  description = "List of CIDR blocks allowed to access the SQL Server database"
  default     = ["0.0.0.0/0"]
}
