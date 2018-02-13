# --------------------------------
# Terraform configuration

terraform {
  required_version = "~> 0.10"
}

provider "aws" {
  version = "~> 1.9.0"
  region  = "us-east-1" # N. Virginia
}

# --------------------------------
# IAM User: website-writer

data "aws_iam_policy_document" "website-writer-policy" {
  statement {
    actions = ["cloudfront:CreateInvalidation"]

    resources = ["*"]
  }
}

resource "aws_iam_user" "website-writer" {
  name          = "${var.website_name}-website-writer"
  force_destroy = true
}

resource "aws_iam_policy" "website-writer-policy" {
  name   = "${var.website_name}-website-writer-policy"
  policy = "${data.aws_iam_policy_document.website-writer-policy.json}"
}

resource "aws_iam_policy_attachment" "website-writer-attachment" {
  name       = "${var.website_name}-website-writer-attachment"
  users      = ["${aws_iam_user.website-writer.name}"]
  policy_arn = "${aws_iam_policy.website-writer-policy.arn}"
}

# --------------------------------
# Route 53 records:

resource "aws_route53_record" "website-cloudfront" {
  zone_id = "${var.website_domain["zone_id"]}"
  name    = "${var.website_domain["name"]}"
  type    = "A"

  alias {
    name                   = "${aws_cloudfront_distribution.website-distribution.domain_name}"
    zone_id                = "${aws_cloudfront_distribution.website-distribution.hosted_zone_id}"
    evaluate_target_health = false
  }
}

# --------------------------------
# ACM:
# Need AWS provider v1.9 or more.
# see: https://github.com/terraform-providers/terraform-provider-aws/pull/2813

resource "aws_acm_certificate" "website" {
  domain_name               = "${var.website_domain["name"]}"
  subject_alternative_names = ["*.${var.website_domain["name"]}"]
  validation_method         = "DNS"
}

resource "aws_route53_record" "website-certificate-validation" {
  name    = "${aws_acm_certificate.website.domain_validation_options.0.resource_record_name}"
  type    = "${aws_acm_certificate.website.domain_validation_options.0.resource_record_type}"
  zone_id = "${var.website_domain["zone_id"]}"
  records = ["${aws_acm_certificate.website.domain_validation_options.0.resource_record_value}"]
  ttl     = 60
}

# for wildcard
resource "aws_route53_record" "_-website-certificate-validation" {
  name    = "${aws_acm_certificate.website.domain_validation_options.1.resource_record_name}"
  type    = "${aws_acm_certificate.website.domain_validation_options.1.resource_record_type}"
  zone_id = "${var.website_domain["zone_id"]}"
  records = ["${aws_acm_certificate.website.domain_validation_options.1.resource_record_value}"]
  ttl     = 60
}

# Note: known issue
#
# * aws_acm_certificate_validation.website: Certificate needs [xxxx.YOURDOMAIN xxxx.YOURDOMAIN] to be set but only [xxxx.YOURDOMAIN] was passed to validation_record_fqdns
#
resource "aws_acm_certificate_validation" "website" {
  certificate_arn = "${aws_acm_certificate.website.arn}"

  validation_record_fqdns = [
    "${aws_route53_record.website-certificate-validation.fqdn}",
    "${aws_route53_record._-website-certificate-validation.fqdn}",
  ]
}

# --------------------------------
# S3 buckets:

data "aws_iam_policy_document" "website-s3-policy" {
  statement {
    actions = [
      "s3:GetObject",
    ]

    resources = [
      "${aws_s3_bucket.website.arn}/*",
    ]

    principals {
      type = "AWS"

      identifiers = ["*"]
    }
  }

  statement {
    actions = ["s3:*"]

    resources = [
      "${aws_s3_bucket.website.arn}",
      "${aws_s3_bucket.website.arn}/*",
    ]

    principals {
      type = "AWS"

      identifiers = [
        "${aws_iam_user.website-writer.arn}",
      ]
    }
  }
}

resource "aws_s3_bucket_policy" "website" {
  bucket = "${aws_s3_bucket.website.id}"
  policy = "${data.aws_iam_policy_document.website-s3-policy.json}"
}

resource "aws_s3_bucket" "website" {
  bucket = "${var.website_name}-website"
  acl    = "public-read"

  website {
    index_document = "index.html"
    error_document = "404.html"
  }

  tags {}

  force_destroy = true
}

resource "aws_s3_bucket" "website-log-s3" {
  bucket = "${var.website_name}-website-log-s3"

  tags {}

  force_destroy = true
}

# --------------------------------
# CloudFront:

resource "aws_cloudfront_distribution" "website-distribution" {
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"
  price_class         = "PriceClass_200"

  origin {
    domain_name = "${aws_s3_bucket.website.website_endpoint}"
    origin_id   = "${var.website_name}-origin"

    custom_origin_config {
      http_port              = "80"
      https_port             = "443"
      origin_protocol_policy = "http-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  logging_config {
    include_cookies = false
    bucket          = "${aws_s3_bucket.website-log-s3.bucket_domain_name}"
    prefix          = "${var.website_name}/"
  }

  aliases = [
    "${var.website_domain["name"]}",
  ]

  default_cache_behavior {
    allowed_methods  = ["GET", "HEAD", "OPTIONS"]
    cached_methods   = ["GET", "HEAD"]
    target_origin_id = "${var.website_name}-origin"
    compress         = true

    forwarded_values {
      query_string = false

      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
    min_ttl                = 0
    default_ttl            = 3600
    max_ttl                = 86400
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    acm_certificate_arn = "${aws_acm_certificate.website.arn}"
    ssl_support_method  = "sni-only"
  }

  tags = {}
}
