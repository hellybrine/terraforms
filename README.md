# Terraform AWS Infrastructure

This repository contains Terraform configurations for AWS infrastructure.

## Scripts

### `deploying-s3.tf`
Creates a private S3 bucket named "rasgarage" with:
- Server-side encryption (AES256)
- Public access blocked
- Versioning disabled

### `image-resizer.tf`
Creates a serverless image resizing service with:
- **S3 Buckets**: Two buckets (private uploads, public resized images)
- **Lambda Function**: Python function that resizes images using Pillow
- **API Gateway**: HTTP API endpoint to upload and resize images
- **IAM Roles**: Permissions for Lambda to access S3 buckets

## Usage

```bash
# Initialize Terraform
terraform init

# Deploy infrastructure
terraform apply

# View outputs (for image-resizer)
terraform output
```

## Requirements

- AWS credentials in `terraform.tfvars`
- Terraform >= 1.0
- For image-resizer: Package Lambda first with `cd lambda && ./package.sh && cd ..`
