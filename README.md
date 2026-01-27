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

### `cost-alerter.tf`
Creates a serverless AWS cost monitoring and alerting system:
- **Lambda Function**: Python function that checks costs via Cost Explorer API
- **EventBridge Rule**: Scheduled trigger (default: every 6 hours)
- **ntfy Integration**: Push notifications when costs exceed thresholds
- **AWS Budget**: Native AWS budget as backup alerting method
- **Auto-Nuke (Optional)**: Automatically stop/terminate resources when critical threshold exceeded

#### Features:
- Monitors current month's AWS spending
- Sends alerts via [ntfy](https://ntfy.sh) for mobile/desktop push notifications
- Forecasts month-end costs
- Breaks down costs by service
- Optional automatic resource cleanup (EC2, NAT Gateways, RDS)
- Configurable alert and critical thresholds
- Daily summary option

#### Cost Alerter Configuration:
```hcl
# In terraform.tfvars
cost_alerter_enabled    = true
cost_alert_threshold    = 10      # Alert when costs exceed $10
cost_critical_threshold = 50      # Critical alert at $50
ntfy_topic              = "my-aws-alerts"  # Your ntfy topic
ntfy_server             = "https://ntfy.sh"
cost_check_schedule     = "rate(6 hours)"  # Check every 6 hours

# DANGER ZONE - Auto resource cleanup
enable_auto_nuke = false  # Set to true to enable (be careful!)
nuke_dry_run     = true   # Set to false to actually terminate resources
```

#### Subscribing to ntfy alerts:
1. Install the ntfy app on your phone ([iOS](https://apps.apple.com/app/ntfy/id1625396347) / [Android](https://play.google.com/store/apps/details?id=io.heckel.ntfy))
2. Subscribe to your topic: `https://ntfy.sh/your-topic-name`
3. You'll receive push notifications when costs exceed your threshold

#### Manual Cost Check:
```bash
# Invoke the Lambda manually to check costs now
aws lambda invoke --function-name image-resizer-cost-alerter --log-type Tail output.json
cat output.json
```

## Usage

```bash
# Initialize Terraform
terraform init

# Deploy infrastructure
terraform apply

# View outputs (for image-resizer)
terraform output

# Test cost alerter manually
aws lambda invoke --function-name $(terraform output -raw cost_alerter_lambda_name) output.json
```

## Requirements

- AWS credentials in `terraform.tfvars`
- Terraform >= 1.0
- For image-resizer: Package Lambda first with `cd lambda && ./package.sh && cd ..`
- For cost-alerter: Cost Explorer API must be enabled in your AWS account (enabled by default)
