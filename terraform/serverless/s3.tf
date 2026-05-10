################################################################################
# s3.tf
# S3 buckets for Phase 2 + 2.5 serverless stack
#
# Buckets:
#   webapp.amitwebsite.online   - public JIT demo landing page  (EXISTING)
#   private.amitwebsite.online  - Cloudflare Access protected   (EXISTING)
#   aws-config-zerotrust-[acct] - AWS Config delivery           (NEW)
#
# EXISTING BUCKETS - import before first apply:
#   terraform import aws_s3_bucket.webapp webapp.amitwebsite.online
#   terraform import aws_s3_bucket.private private.amitwebsite.online
#   terraform import aws_s3_bucket_website_configuration.webapp webapp.amitwebsite.online
#   terraform import aws_s3_bucket_website_configuration.private private.amitwebsite.online
#   terraform import aws_s3_bucket_public_access_block.webapp webapp.amitwebsite.online
#   terraform import aws_s3_bucket_public_access_block.private private.amitwebsite.online
#
# On first apply Terraform will ADD:
#   - Cloudflare IP allowlist bucket policy (both ZTNA buckets)
#   - Versioning + SSE (reconcile to desired state)
#
# Security model:
#   ZTNA buckets: Cloudflare IPs only + SSL enforced (orange cloud, never direct)
#   Config bucket: Config service only + SSL enforced, fully private
#
# NEVER put CloudFront in front of ZTNA buckets - breaks Cloudflare Access
################################################################################

################################################################################
# Cloudflare IP ranges - https://www.cloudflare.com/ips-v4
################################################################################

locals {
  cloudflare_ipv4_cidrs = [
    "173.245.48.0/20",
    "103.21.244.0/22",
    "103.22.200.0/22",
    "103.31.4.0/22",
    "141.101.64.0/18",
    "108.162.192.0/18",
    "190.93.240.0/20",
    "188.114.96.0/20",
    "197.234.240.0/22",
    "198.41.128.0/17",
    "162.158.0.0/15",
    "104.16.0.0/13",
    "104.24.0.0/14",
    "172.64.0.0/13",
    "131.0.72.0/22",
  ]
}

################################################################################
# webapp.amitwebsite.online - EXISTING BUCKET
################################################################################

resource "aws_s3_bucket" "webapp" {
  bucket = local.webapp_bucket_name

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name    = local.webapp_bucket_name
    Purpose = "ZTNA webapp - JIT demo landing page"
  }
}

resource "aws_s3_bucket_public_access_block" "webapp" {
  bucket = aws_s3_bucket.webapp.id

  # false required - S3 website hosting + bucket policy must coexist
  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_website_configuration" "webapp" {
  bucket = aws_s3_bucket.webapp.id
  index_document { suffix = "index.html" }
  error_document { key    = "index.html" }
}

resource "aws_s3_bucket_versioning" "webapp" {
  bucket = aws_s3_bucket.webapp.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "webapp" {
  bucket = aws_s3_bucket.webapp.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_policy" "webapp" {
  bucket     = aws_s3_bucket.webapp.id
  depends_on = [aws_s3_bucket_public_access_block.webapp]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowCloudflareIPsOnly"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.webapp.arn}/*"
        Condition = {
          IpAddress = { "aws:SourceIp" = local.cloudflare_ipv4_cidrs }
        }
      }
    ]
  })
}

################################################################################
# private.amitwebsite.online - EXISTING BUCKET
################################################################################

resource "aws_s3_bucket" "private" {
  bucket = local.private_bucket_name

  lifecycle {
    prevent_destroy = true
  }

  tags = {
    Name    = local.private_bucket_name
    Purpose = "ZTNA private page - behind Cloudflare Access JITDemo policy"
  }
}

resource "aws_s3_bucket_public_access_block" "private" {
  bucket = aws_s3_bucket.private.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

resource "aws_s3_bucket_website_configuration" "private" {
  bucket = aws_s3_bucket.private.id
  index_document { suffix = "index.html" }
  error_document { key    = "index.html" }
}

resource "aws_s3_bucket_versioning" "private" {
  bucket = aws_s3_bucket.private.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "private" {
  bucket = aws_s3_bucket.private.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_policy" "private" {
  bucket     = aws_s3_bucket.private.id
  depends_on = [aws_s3_bucket_public_access_block.private]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowCloudflareIPsOnly"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.private.arn}/*"
        Condition = {
          IpAddress = { "aws:SourceIp" = local.cloudflare_ipv4_cidrs }
        }
      }
    ]
  })
}

################################################################################
# aws-config-zerotrust-[account-id] - NEW BUCKET
# Referenced by config.tf delivery channel
################################################################################

resource "aws_s3_bucket" "config_logs" {
  bucket = "aws-config-zerotrust-${local.account_id}"

  tags = {
    Name    = "aws-config-zerotrust-${local.account_id}"
    Purpose = "AWS Config delivery channel - compliance snapshots"
  }
}

resource "aws_s3_bucket_public_access_block" "config_logs" {
  bucket                  = aws_s3_bucket.config_logs.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_versioning" "config_logs" {
  bucket = aws_s3_bucket.config_logs.id
  versioning_configuration { status = "Enabled" }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "config_logs" {
  bucket = aws_s3_bucket.config_logs.id
  rule {
    apply_server_side_encryption_by_default { sse_algorithm = "AES256" }
  }
}

resource "aws_s3_bucket_lifecycle_configuration" "config_logs" {
  bucket = aws_s3_bucket.config_logs.id
  rule {
    id     = "expire-old-config-snapshots"
    status = "Enabled"
    filter {}
    expiration { days = 90 }
    noncurrent_version_expiration { noncurrent_days = 30 }
  }
}

resource "aws_s3_bucket_policy" "config_logs" {
  bucket     = aws_s3_bucket.config_logs.id
  depends_on = [aws_s3_bucket_public_access_block.config_logs]

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "AllowConfigServiceAclCheck"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = "s3:GetBucketAcl"
        Resource  = aws_s3_bucket.config_logs.arn
        Condition = { StringEquals = { "AWS:SourceAccount" = local.account_id } }
      },
      {
        Sid       = "AllowConfigServiceWrite"
        Effect    = "Allow"
        Principal = { Service = "config.amazonaws.com" }
        Action    = "s3:PutObject"
        Resource  = "${aws_s3_bucket.config_logs.arn}/AWSLogs/${local.account_id}/Config/*"
        Condition = {
          StringEquals = {
            "s3:x-amz-acl"      = "bucket-owner-full-control"
            "AWS:SourceAccount" = local.account_id
          }
        }
      },
      {
        Sid       = "DenyNonSSL"
        Effect    = "Deny"
        Principal = "*"
        Action    = "s3:*"
        Resource  = [aws_s3_bucket.config_logs.arn, "${aws_s3_bucket.config_logs.arn}/*"]
        Condition = { Bool = { "aws:SecureTransport" = "false" } }
      }
    ]
  })
}
