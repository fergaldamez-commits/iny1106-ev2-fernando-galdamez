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
            image_data = body.encode('utf-8')
        else:
            image_data = body

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
