resource "aws_security_group" "rds_sg" {
  name        = "rds-logship-sg"
  description = "Allow SQL Server traffic from allowed CIDR blocks"
  vpc_id      = aws_vpc.main.id

  ingress {
    description = "SQL Server access"
    from_port   = 1433
    to_port     = 1433
    protocol    = "tcp"
    cidr_blocks = var.allowed_cidr_blocks
  }

  egress {
    from_port        = 0
    to_port          = 0
    protocol         = "-1"
    cidr_blocks      = ["0.0.0.0/0"]
    ipv6_cidr_blocks = ["::/0"]
  }

  tags = {
    Name = "rds-logship-sg"
  }
}
