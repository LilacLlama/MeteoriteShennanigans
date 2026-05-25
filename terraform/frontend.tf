# ── Frontend: S3 + CloudFront ─────────────────────────────────────────────────
#
# S3 holds the built React/Vite assets. CloudFront sits in front as a global
# CDN — it caches files at ~450 edge locations and handles HTTPS via its own
# default certificate (*.cloudfront.net). No custom domain or ACM cert needed
# for a demo; add those later if you want a vanity URL.
#
# Security model: the S3 bucket is fully private. CloudFront accesses it via
# Origin Access Control (OAC) — a signed request mechanism that proves the
# request came from this specific CloudFront distribution. Public S3 website
# hosting is intentionally NOT used.
#
# SPA routing: any path that doesn't match a file (e.g. a browser refresh on
# a deep link) returns index.html with a 200 rather than a 404. React Router
# then handles the route client-side.
#
# Cache strategy (set by the deploy workflow, not Terraform):
#   /index.html       → Cache-Control: no-cache   (always check for new version)
#   /assets/**        → Cache-Control: max-age=31536000, immutable
#                        (Vite content-hashes filenames; safe to cache forever)

# ── S3 bucket ─────────────────────────────────────────────────────────────────

resource "aws_s3_bucket" "frontend" {
  bucket = "${var.app_name}-frontend"
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# ── CloudFront Origin Access Control ─────────────────────────────────────────
# OAC signs every CloudFront → S3 request with SigV4. The bucket policy below
# only allows requests that carry this distribution's signature.

resource "aws_cloudfront_origin_access_control" "frontend" {
  name                              = "${var.app_name}-frontend"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

# ── CloudFront distribution ───────────────────────────────────────────────────

resource "aws_cloudfront_distribution" "frontend" {
  enabled             = true
  default_root_object = "index.html"
  price_class         = "PriceClass_100" # US + Europe edge locations only; cheapest tier

  origin {
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id                = "S3-${var.app_name}-frontend"
    origin_access_control_id = aws_cloudfront_origin_access_control.frontend.id
  }

  default_cache_behavior {
    target_origin_id       = "S3-${var.app_name}-frontend"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    viewer_protocol_policy = "redirect-to-https"
    compress               = true

    forwarded_values {
      query_string = false
      cookies { forward = "none" }
    }

    # TTLs are intentionally low here; the deploy workflow sets Cache-Control
    # headers on individual files so CloudFront respects those per-file values.
    min_ttl     = 0
    default_ttl = 0
    max_ttl     = 31536000
  }

  # Return index.html (200) for any path that doesn't match a file.
  # This is what makes React client-side routing work on direct URL loads
  # and browser refreshes — without it you'd get a 403 from S3.
  custom_error_response {
    error_code         = 403
    response_code      = 200
    response_page_path = "/index.html"
  }

  custom_error_response {
    error_code         = 404
    response_code      = 200
    response_page_path = "/index.html"
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true # uses *.cloudfront.net SSL cert
  }
}

# ── Bucket policy: allow only this CloudFront distribution ────────────────────

resource "aws_s3_bucket_policy" "frontend" {
  bucket = aws_s3_bucket.frontend.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Sid    = "AllowCloudFrontOAC"
      Effect = "Allow"
      Principal = {
        Service = "cloudfront.amazonaws.com"
      }
      Action   = "s3:GetObject"
      Resource = "${aws_s3_bucket.frontend.arn}/*"
      Condition = {
        StringEquals = {
          "AWS:SourceArn" = aws_cloudfront_distribution.frontend.arn
        }
      }
    }]
  })
}

# ── Outputs ───────────────────────────────────────────────────────────────────

output "frontend_bucket" {
  description = "S3 bucket name — used by deploy-frontend.yml for aws s3 sync"
  value       = aws_s3_bucket.frontend.id
}

output "cloudfront_distribution_id" {
  description = "CloudFront distribution ID — used by deploy-frontend.yml for cache invalidation"
  value       = aws_cloudfront_distribution.frontend.id
}

output "frontend_url" {
  description = "Public URL of the frontend"
  value       = "https://${aws_cloudfront_distribution.frontend.domain_name}"
}
