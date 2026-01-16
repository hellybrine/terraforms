# AWS Config Helm Chart

Helm chart for deploying applications with AWS credentials and configuration.

## Installation

```bash
# Install the chart
helm install aws-config ./helm-chart

# Install with custom values
helm install aws-config ./helm-chart -f my-values.yaml

# Upgrade existing release
helm upgrade aws-config ./helm-chart
```

## Configuration

Default AWS credentials are embedded in `values.yaml`:
- Access Key ID: AKIAZ6Z5IX4RLRVW22KX
- Secret Access Key: (stored in Secret)
- Region: us-east-2
- Output: json

## What Gets Deployed

- **ConfigMap**: AWS region and output format
- **Secret**: AWS access key and secret key (base64 encoded)
- **Deployment**: Application with AWS credentials as environment variables
- **Service**: ClusterIP service exposing the application

## Security Note

⚠️ **WARNING**: This chart contains AWS credentials in `values.yaml`. 
- Do not commit this to version control
- Use Kubernetes Secrets in production
- Consider using IAM roles for service accounts (IRSA) instead of static credentials

## Usage

The AWS credentials are available as environment variables in the deployed pods:
- `AWS_ACCESS_KEY_ID`
- `AWS_SECRET_ACCESS_KEY`
- `AWS_REGION`
- `AWS_OUTPUT`
