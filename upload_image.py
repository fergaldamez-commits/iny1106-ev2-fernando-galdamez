import json
import os
import uuid
import base64
import datetime
import boto3

s3 = boto3.client('s3')
dynamodb = boto3.resource('dynamodb')

BUCKET_NAME = os.environ.get('BUCKET_NAME')
TABLE_NAME = os.environ.get('TABLE_NAME')
table = dynamodb.Table(TABLE_NAME)

def lambda_handler(event, context):
    try:
        is_b64 = event.get('isBase64Encoded', False)
        body = event.get('body', '')

        if is_b64:
            image_data = base64.b64decode(body)
        elif isinstance(body, str):
            image_data = body.encode('latin-1')
        else:
            image_data = body

        # Si el cliente (ej. Postman) envió la imagen como multipart/form-data,
        # extraemos automáticamente los bytes reales del JPEG (desde \xff\xd8 hasta \xff\xd9)
        jpeg_start = image_data.find(b'\xff\xd8\xff')
        if jpeg_start > 0:
            jpeg_end = image_data.rfind(b'\xff\xd9')
            if jpeg_end != -1:
                image_data = image_data[jpeg_start:jpeg_end + 2]
            else:
                image_data = image_data[jpeg_start:]

        image_id = str(uuid.uuid4())
        s3_key = f"images/{image_id}.jpg"
        size_bytes = len(image_data)
        timestamp = datetime.datetime.now(datetime.timezone.utc).isoformat()

        # Subir a S3
        s3.put_object(
            Bucket=BUCKET_NAME,
            Key=s3_key,
            Body=image_data,
            ContentType='image/jpeg'
        )

        # Guardar metadatos en DynamoDB
        metadata_item = {
            'image_id': image_id,
            'bucket_name': BUCKET_NAME,
            's3_key': s3_key,
            'size_bytes': size_bytes,
            'upload_date': timestamp
        }
        table.put_item(Item=metadata_item)

        return {
            'statusCode': 200,
            'headers': {
                'Content-Type': 'application/json',
                'Access-Control-Allow-Origin': '*'
            },
            'body': json.dumps(metadata_item)
        }
    except Exception as e:
        return {
            'statusCode': 500,
            'headers': {
                'Content-Type': 'application/json',
                'Access-Control-Allow-Origin': '*'
            },
            'body': json.dumps({'error': str(e)})
        }
