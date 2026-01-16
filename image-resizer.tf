resource "aws_s3_bucket" "image_uploads" {
  bucket = "${var.project_name}-image-uploads-${random_id.bucket_suffix.hex}"

  tags = {
    Name        = "${var.project_name}-uploads"
    Environment = var.environment
    Project     = "Image Resizer"
  }
}

# Bucket for resized images
resource "aws_s3_bucket" "resized_images" {
  bucket = "${var.project_name}-resized-images-${random_id.bucket_suffix.hex}"

  tags = {
    Name        = "${var.project_name}-resized"
    Environment = var.environment
    Project     = "Image Resizer"
  }
}

# Random suffix to ensure bucket name uniqueness
resource "random_id" "bucket_suffix" {
  byte_length = 4
}

# Enable versioning on upload bucket (optional, for safety)
resource "aws_s3_bucket_versioning" "image_uploads" {
  bucket = aws_s3_bucket.image_uploads.id
  versioning_configuration {
    status = "Enabled"
  }
}

# Enable encryption on both buckets
resource "aws_s3_bucket_server_side_encryption_configuration" "image_uploads" {
  bucket = aws_s3_bucket.image_uploads.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "resized_images" {
  bucket = aws_s3_bucket.resized_images.id

  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

# Block public access on upload bucket (private)
resource "aws_s3_bucket_public_access_block" "image_uploads" {
  bucket = aws_s3_bucket.image_uploads.id

  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# Allow public read access to resized images (so they can be viewed)
resource "aws_s3_bucket_public_access_block" "resized_images" {
  bucket = aws_s3_bucket.resized_images.id

  block_public_acls       = false
  block_public_policy     = false
  ignore_public_acls      = false
  restrict_public_buckets = false
}

# Make resized images bucket publicly readable
resource "aws_s3_bucket_policy" "resized_images" {
  bucket = aws_s3_bucket.resized_images.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "PublicReadGetObject"
        Effect    = "Allow"
        Principal = "*"
        Action    = "s3:GetObject"
        Resource  = "${aws_s3_bucket.resized_images.arn}/*"
      }
    ]
  })
}

# CORS configuration for upload bucket (to allow browser uploads)
resource "aws_s3_bucket_cors_configuration" "image_uploads" {
  bucket = aws_s3_bucket.image_uploads.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["PUT", "POST", "GET"]
    allowed_origins = ["*"] # In production, restrict this to your domain
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}

# ----------------------------------------------------------------------------
# IAM Role for Lambda Function
# ----------------------------------------------------------------------------

# IAM role that Lambda will assume
resource "aws_iam_role" "image_resizer_lambda" {
  name = "${var.project_name}-image-resizer-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Action = "sts:AssumeRole"
        Effect = "Allow"
        Principal = {
          Service = "lambda.amazonaws.com"
        }
      }
    ]
  })

  tags = {
    Name        = "${var.project_name}-lambda-role"
    Environment = var.environment
  }
}

# Policy to allow Lambda to read from upload bucket and write to resized bucket
resource "aws_iam_role_policy" "image_resizer_s3_access" {
  name = "${var.project_name}-s3-access"
  role = aws_iam_role.image_resizer_lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect = "Allow"
        Action = [
          "s3:GetObject",
          "s3:GetObjectVersion"
        ]
        Resource = "${aws_s3_bucket.image_uploads.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:PutObjectAcl"
        ]
        Resource = "${aws_s3_bucket.resized_images.arn}/*"
      },
      {
        Effect = "Allow"
        Action = [
          "logs:CreateLogGroup",
          "logs:CreateLogStream",
          "logs:PutLogEvents"
        ]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# ----------------------------------------------------------------------------
# Lambda Function
# ----------------------------------------------------------------------------

# Archive the Lambda function code
# Note: If you've packaged with dependencies using package.sh, 
# this will create a zip from the Python file.
# For production, you should package with dependencies first.
data "archive_file" "lambda_zip" {
  type        = "zip"
  source_file = "${path.module}/lambda/image_resizer.py"
  output_path = "${path.module}/lambda/image_resizer.zip"
  
  # If you have a pre-packaged zip with dependencies, use this instead:
  # source_dir  = "${path.module}/lambda/package"
  # output_path = "${path.module}/lambda/image_resizer.zip"
}

# Lambda function for image resizing
resource "aws_lambda_function" "image_resizer" {
  filename         = data.archive_file.lambda_zip.output_path
  function_name    = "${var.project_name}-image-resizer"
  role             = aws_iam_role.image_resizer_lambda.arn
  handler          = "image_resizer.lambda_handler"
  source_code_hash = data.archive_file.lambda_zip.output_base64sha256
  runtime          = "python3.11"
  timeout          = 30
  memory_size      = 512 # More memory = faster processing

  environment {
    variables = {
      UPLOAD_BUCKET   = aws_s3_bucket.image_uploads.id
      RESIZED_BUCKET  = aws_s3_bucket.resized_images.id
      RESIZED_WIDTH   = var.default_resized_width
      RESIZED_HEIGHT  = var.default_resized_height
    }
  }

  tags = {
    Name        = "${var.project_name}-image-resizer"
    Environment = var.environment
  }
}

# ----------------------------------------------------------------------------
# API Gateway
# ----------------------------------------------------------------------------

# API Gateway REST API
resource "aws_apigatewayv2_api" "image_resizer_api" {
  name          = "${var.project_name}-image-resizer-api"
  protocol_type = "HTTP"
  description   = "API for uploading and resizing images"

  cors_configuration {
    allow_origins = ["*"] # In production, restrict this
    allow_methods = ["GET", "POST", "OPTIONS"]
    allow_headers = ["content-type", "x-amz-date", "authorization", "x-api-key"]
  }

  tags = {
    Name        = "${var.project_name}-api"
    Environment = var.environment
  }
}

# Integration between API Gateway and Lambda
resource "aws_apigatewayv2_integration" "lambda_integration" {
  api_id           = aws_apigatewayv2_api.image_resizer_api.id
  integration_type = "AWS_PROXY"

  integration_method   = "POST"
  integration_uri      = aws_lambda_function.image_resizer.invoke_arn
  payload_format_version = "2.0"
}

# Permission for API Gateway to invoke Lambda
resource "aws_lambda_permission" "api_gateway" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.image_resizer.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.image_resizer_api.execution_arn}/*/*"
}

# POST route for uploading/resizing images
resource "aws_apigatewayv2_route" "resize_image" {
  api_id    = aws_apigatewayv2_api.image_resizer_api.id
  route_key = "POST /resize"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

# GET route for health check
resource "aws_apigatewayv2_route" "health" {
  api_id    = aws_apigatewayv2_api.image_resizer_api.id
  route_key = "GET /health"
  target    = "integrations/${aws_apigatewayv2_integration.lambda_integration.id}"
}

# API Gateway stage (deployment)
resource "aws_apigatewayv2_stage" "default" {
  api_id      = aws_apigatewayv2_api.image_resizer_api.id
  name        = "$default"
  auto_deploy = true

  tags = {
    Name        = "${var.project_name}-api-stage"
    Environment = var.environment
  }
}

# ----------------------------------------------------------------------------
# Outputs
# ----------------------------------------------------------------------------

output "api_endpoint" {
  description = "API Gateway endpoint URL"
  value       = aws_apigatewayv2_api.image_resizer_api.api_endpoint
}

output "upload_bucket_name" {
  description = "Name of the S3 bucket for uploads"
  value       = aws_s3_bucket.image_uploads.id
}

output "resized_bucket_name" {
  description = "Name of the S3 bucket for resized images"
  value       = aws_s3_bucket.resized_images.id
}

output "resize_endpoint" {
  description = "Full endpoint URL for resizing images"
  value       = "${aws_apigatewayv2_api.image_resizer_api.api_endpoint}/resize"
}

output "health_check_endpoint" {
  description = "Health check endpoint URL"
  value       = "${aws_apigatewayv2_api.image_resizer_api.api_endpoint}/health"
}
