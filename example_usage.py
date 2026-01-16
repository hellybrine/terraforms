import requests
import base64
import json
import sys

API_ENDPOINT = "YOUR_API_ENDPOINT_HERE"  # Replace with: terraform output -raw resize_endpoint

def resize_image(image_path, width=None, height=None, filename=None):
    try:
        with open(image_path, 'rb') as f:
            image_data = base64.b64encode(f.read()).decode('utf-8')
    except FileNotFoundError:
        print(f"Error: File '{image_path}' not found")
        return None
    
    # Prepare request
    url = f"{API_ENDPOINT}/resize"
    params = {}
    if width:
        params['width'] = width
    if height:
        params['height'] = height
    if filename:
        params['filename'] = filename
    
    payload = {"body": image_data}
    
    print(f"Uploading and resizing image: {image_path}")
    if params:
        print(f"Parameters: {params}")
    
    # Make request
    try:
        response = requests.post(url, json=payload, params=params, timeout=60)
        response.raise_for_status()
        
        result = response.json()
        
        if result.get('success'):
            print(f"\n✅ Success!")
            print(f"Resized image URL: {result['resized_url']}")
            print(f"Filename: {result['filename']}")
            print(f"Content Type: {result['content_type']}")
            return result['resized_url']
        else:
            print(f"❌ Error: {result.get('error', 'Unknown error')}")
            return None
            
    except requests.exceptions.RequestException as e:
        print(f"❌ Request failed: {e}")
        if hasattr(e.response, 'text'):
            print(f"Response: {e.response.text}")
        return None


def health_check():
    """Check if the API is healthy"""
    url = f"{API_ENDPOINT.replace('/resize', '/health')}"
    
    try:
        response = requests.get(url, timeout=10)
        response.raise_for_status()
        result = response.json()
        print(f"✅ API Status: {result.get('status', 'unknown')}")
        return True
    except Exception as e:
        print(f"❌ Health check failed: {e}")
        return False


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("Usage: python example_usage.py <image_path> [width] [height]")
        print("\nExample:")
        print("  python example_usage.py photo.jpg 800 600")
        print("  python example_usage.py photo.jpg 400")  # Width only, maintains aspect ratio
        print("\nHealth check:")
        print("  python example_usage.py --health")
        sys.exit(1)
    
    if sys.argv[1] == "--health":
        health_check()
        sys.exit(0)
    
    image_path = sys.argv[1]
    width = int(sys.argv[2]) if len(sys.argv) > 2 else None
    height = int(sys.argv[3]) if len(sys.argv) > 3 else None
    
    resize_image(image_path, width, height)
