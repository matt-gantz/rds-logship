data "aws_rds_engine_version" "sqlserver_express_2022" {
  engine  = "sqlserver-ex"
  version = "16.00"
  latest  = true
}

resource "aws_db_instance" "sql_server" {
  identifier             = "rds-logship-db"
  engine                 = "sqlserver-ex"
  engine_version         = data.aws_rds_engine_version.sqlserver_express_2022.version
  instance_class         = "db.t3.micro"
  allocated_storage      = 20
  storage_type           = "gp2"
  username               = var.db_admin_username
  password               = var.db_password
  publicly_accessible    = true
  db_subnet_group_name   = aws_db_subnet_group.db_subnet_group.name
  vpc_security_group_ids = [aws_security_group.rds_sg.id]

  # Disable backups and snapshots for demo speed & cost efficiency
  backup_retention_period = 0
  skip_final_snapshot     = true
  deletion_protection     = false

  option_group_name = aws_db_option_group.sqlserver_option_group.name

  tags = {
    Name = "rds-logship-db"
  }
}
