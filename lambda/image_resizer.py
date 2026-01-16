import json
import boto3
import os
from io import BytesIO
from PIL import Image

s3_client = boto3.client('s3')

# Get environment variables
UPLOAD_BUCKET = os.environ['UPLOAD_BUCKET']
RESIZED_BUCKET = os.environ['RESIZED_BUCKET']
DEFAULT_WIDTH = int(os.environ.get('RESIZED_WIDTH', 800))
DEFAULT_HEIGHT = int(os.environ.get('RESIZED_HEIGHT', 600))


def resize_image(image_data, width=None, height=None):
    image = Image.open(BytesIO(image_data))
    
    original_width, original_height = image.size
    
    # Calculate new dimensions maintaining aspect ratio
    if width and height:
        # Use provided dimensions
        new_width = width
        new_height = height
    elif width:
        # Scale based on width
        ratio = width / original_width
        new_width = width
        new_height = int(original_height * ratio)
    elif height:
        # Scale based on height
        ratio = height / original_height
        new_width = int(original_width * ratio)
        new_height = height
    else:
        # Use default dimensions
        ratio = min(DEFAULT_WIDTH / original_width, DEFAULT_HEIGHT / original_height)
        new_width = int(original_width * ratio)
        new_height = int(original_height * ratio)
    
    # Resize image
    resized_image = image.resize((new_width, new_height), Image.Resampling.LANCZOS)
    
    # Convert to bytes
    output = BytesIO()
    
    # Determine format and save
    if image.format == 'PNG':
        resized_image.save(output, format='PNG')
        content_type = 'image/png'
    elif image.format == 'JPEG' or image.format == 'JPG':
        # Convert RGBA to RGB if needed (JPEG doesn't support transparency)
        if resized_image.mode == 'RGBA':
            rgb_image = Image.new('RGB', resized_image.size, (255, 255, 255))
            rgb_image.paste(resized_image, mask=resized_image.split()[3])
            resized_image = rgb_image
        resized_image.save(output, format='JPEG', quality=85)
        content_type = 'image/jpeg'
    else:
        # Default to JPEG
        if resized_image.mode == 'RGBA':
            rgb_image = Image.new('RGB', resized_image.size, (255, 255, 255))
            rgb_image.paste(resized_image, mask=resized_image.split()[3])
            resized_image = rgb_image
        resized_image.save(output, format='JPEG', quality=85)
        content_type = 'image/jpeg'
    
    output.seek(0)
    return output.read(), content_type


def lambda_handler(event, context):
    try:
        # Handle health check
        if event.get('routeKey') == 'GET /health':
            return {
                'statusCode': 200,
                'headers': {
                    'Content-Type': 'application/json',
                    'Access-Control-Allow-Origin': '*'
                },
                'body': json.dumps({
                    'status': 'healthy',
                    'service': 'image-resizer'
                })
            }
        
        # Parse request
        body = event.get('body', '')
        query_params = event.get('queryStringParameters') or {}
        
        # Get optional dimensions from query parameters
        width = int(query_params.get('width', 0)) if query_params.get('width') else None
        height = int(query_params.get('height', 0)) if query_params.get('height') else None
        
        # Get filename (default to 'resized-image.jpg')
        filename = query_params.get('filename', 'resized-image.jpg')
        
        # Decode base64 image if provided in body
        if body:
            import base64
            # Handle base64 with or without data URL prefix
            if body.startswith('data:'):
                body = body.split(',')[1]
            image_data = base64.b64decode(body)
        else:
            return {
                'statusCode': 400,
                'headers': {
                    'Content-Type': 'application/json',
                    'Access-Control-Allow-Origin': '*'
                },
                'body': json.dumps({
                    'error': 'No image data provided in request body'
                })
            }
        
        # Resize the image
        resized_data, content_type = resize_image(image_data, width, height)
        
        # Generate unique filename
        import uuid
        file_extension = filename.split('.')[-1] if '.' in filename else 'jpg'
        resized_filename = f"{uuid.uuid4()}.{file_extension}"
        
        # Upload resized image to S3
        s3_client.put_object(
            Bucket=RESIZED_BUCKET,
            Key=resized_filename,
            Body=resized_data,
            ContentType=content_type,
            ACL='public-read'  # Make it publicly accessible
        )
        
        # Generate public URL
        resized_url = f"https://{RESIZED_BUCKET}.s3.amazonaws.com/{resized_filename}"
        
        # Return success response
        return {
            'statusCode': 200,
            'headers': {
                'Content-Type': 'application/json',
                'Access-Control-Allow-Origin': '*'
            },
            'body': json.dumps({
                'success': True,
                'message': 'Image resized successfully',
                'resized_url': resized_url,
                'filename': resized_filename,
                'content_type': content_type
            })
        }
    
    except Exception as e:
        # Log error
        print(f"Error processing image: {str(e)}")
        
        # Return error response
        return {
            'statusCode': 500,
            'headers': {
                'Content-Type': 'application/json',
                'Access-Control-Allow-Origin': '*'
            },
            'body': json.dumps({
                'success': False,
                'error': str(e)
            })
        }
