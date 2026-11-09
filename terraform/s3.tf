resource "random_id" "bucket_suffix" {
  byte_length = 4
}

locals {
  backup_prefixes = toset([
    "backups/LSDemo/",
    "backups/LSDemo/Full/",
    "backups/LSDemo/Log/",
  ])
}

resource "aws_s3_bucket" "demo_bucket" {
  bucket        = "rds-logship-demo-${random_id.bucket_suffix.hex}"
  force_destroy = true # Convenient for tearing down demos

  # Prevent Terraform from ever attempting to destroy/replace an existing bucket if random_id fluctuates
  lifecycle {
    ignore_changes = [bucket]
  }

  tags = {
    Name = "rds-logship-demo-bucket"
  }
}

# Enable block public access settings for the bucket
resource "aws_s3_bucket_public_access_block" "public_access" {
  bucket = aws_s3_bucket.demo_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_object" "backup_prefixes" {
  for_each = local.backup_prefixes

  bucket  = aws_s3_bucket.demo_bucket.id
  key     = each.value
  content = ""

  tags = {
    Name = replace(trim(each.value, "/"), "/", "-")
  }
}
