data "aws_caller_identity" "current" {}

locals {
  account_id  = data.aws_caller_identity.current.account_id
  bucket_name = "${var.project_name}-tf-state-${local.account_id}-${var.aws_region}"
}

# ──────────────────────────────────────────────
# KMS Key configuration for S3 State Encryption
# ──────────────────────────────────────────────

resource "aws_kms_key" "state_key" {
  description             = "KMS Key for Terraform State S3 Bucket"
  deletion_window_in_days = 30
  enable_key_rotation     = true

  tags = {
    Name = "${var.project_name}-tf-state-key"
  }
}

resource "aws_kms_alias" "state_key_alias" {
  name          = "alias/${var.project_name}-tf-state-key"
  target_key_id = aws_kms_key.state_key.key_id
}

# ──────────────────────────────────────────────
# S3 State Bucket configuration
# ──────────────────────────────────────────────

resource "aws_s3_bucket" "state_bucket" {
  bucket        = local.bucket_name
  force_destroy = false

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name = local.bucket_name
  }
}

# Enable Versioning
resource "aws_s3_bucket_versioning" "state_bucket_versioning" {
  bucket = aws_s3_bucket.state_bucket.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Block Public Access
resource "aws_s3_bucket_public_access_block" "state_bucket_public_access" {
  bucket = aws_s3_bucket.state_bucket.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Enforce Bucket Owner Controls (disable ACLs)
resource "aws_s3_bucket_ownership_controls" "state_bucket_ownership" {
  bucket = aws_s3_bucket.state_bucket.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Server-Side Encryption (SSE-KMS) with Bucket Key
resource "aws_s3_bucket_server_side_encryption_configuration" "state_bucket_encryption" {
  bucket = aws_s3_bucket.state_bucket.id

  rule {
    apply_server_side_encryption_by_default {
      kms_master_key_id = aws_kms_key.state_key.arn
      sse_algorithm     = "aws:kms"
    }
    bucket_key_enabled = true
  }
}

# Enforce TLS-only requests
resource "aws_s3_bucket_policy" "state_bucket_policy" {
  bucket = aws_s3_bucket.state_bucket.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "EnforceTLSRequestsOnly"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource = [
          aws_s3_bucket.state_bucket.arn,
          "${aws_s3_bucket.state_bucket.arn}/*"
        ]
        Condition = {
          Bool = {
            "aws:SecureTransport" = "false"
          }
        }
      }
    ]
  })

  depends_on = [aws_s3_bucket_public_access_block.state_bucket_public_access]
}

# Lifecycle Retention Policy
resource "aws_s3_bucket_lifecycle_configuration" "state_bucket_lifecycle" {
  bucket = aws_s3_bucket.state_bucket.id

  rule {
    id     = "terraform-state-retention"
    status = "Enabled"

    filter {}

    noncurrent_version_expiration {
      noncurrent_days = 90
    }

    abort_incomplete_multipart_upload {
      days_after_initiation = 7
    }
  }
}
