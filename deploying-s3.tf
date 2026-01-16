terraform {
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

variable "aws_access_key" {
  description = "AWS Access Key ID"
  type        = string
  sensitive   = true
}

variable "aws_secret_key" {
  description = "AWS Secret Access Key"
  type        = string
  sensitive   = true
}

provider "aws" {
  region     = "ap-south-1"
  access_key = var.aws_access_key
  secret_key = var.aws_secret_key
}

resource "aws_s3_bucket" "garage" {
  bucket = "rasgarage"
}

resource "aws_s3_bucket_versioning" "garage" {
  bucket = aws_s3_bucket.garage.id
  versioning_configuration {
    status = "Disabled"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "garage" {
  bucket = aws_s3_bucket.garage.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_public_access_block" "garage" {
  bucket = aws_s3_bucket.garage.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets  = true
}
