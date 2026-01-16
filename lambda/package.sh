set -e

echo "Creating Lambda deployment package..."

# Create a temporary directory
mkdir -p package
cd package

# Install dependencies
pip install -r ../requirements.txt -t .

# Copy the Lambda function
cp ../image_resizer.py .

# Create zip file
zip -r ../image_resizer.zip .

# Cleanup
cd ..
rm -rf package

echo "Package created: image_resizer.zip"
echo "Size: $(du -h image_resizer.zip | cut -f1)"
