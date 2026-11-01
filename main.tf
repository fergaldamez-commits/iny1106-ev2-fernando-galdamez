terraform {
  required_version = ">= 1.0.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }
}

provider "aws" {
  region = "us-east-1"
}

# Tabla DynamoDB
resource "aws_dynamodb_table" "image_metadata" {
  name         = "ImageMetadata"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "image_id"

  attribute {
    name = "image_id"
    type = "S"
  }

  tags = {
    Environment = "Lab"
    Project     = "ImageMetadataAPI"
  }
}

# Referencia al Bucket S3 existente
data "aws_s3_bucket" "image_bucket" {
  bucket = "my-image-storage-bucket-20f07620"
}

# LabRole existente del laboratorio
data "aws_iam_role" "lab_role" {
  name = "LabRole"
}

# Lambda 1: upload_image
resource "aws_lambda_function" "upload_image" {
  function_name    = "upload_image"
  role             = data.aws_iam_role.lab_role.arn
  handler          = "upload_image.lambda_handler"
  runtime          = "python3.11"
  timeout          = 30
  memory_size      = 128
  filename         = "${path.module}/lambdas/upload_image.zip"
  source_code_hash = filebase64sha256("${path.module}/lambdas/upload_image.zip")

  environment {
    variables = {
      BUCKET_NAME = data.aws_s3_bucket.image_bucket.bucket
      TABLE_NAME  = aws_dynamodb_table.image_metadata.name
    }
  }

  tags = {
    Environment = "Lab"
    Project     = "ImageMetadataAPI"
  }
}

# Lambda 2: get_image_metadata
resource "aws_lambda_function" "get_image_metadata" {
  function_name    = "get_image_metadata"
  role             = data.aws_iam_role.lab_role.arn
  handler          = "get_image_metadata.lambda_handler"
  runtime          = "python3.11"
  timeout          = 30
  memory_size      = 128
  filename         = "${path.module}/lambdas/get_image_metadata.zip"
  source_code_hash = filebase64sha256("${path.module}/lambdas/get_image_metadata.zip")

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.image_metadata.name
    }
  }

  tags = {
    Environment = "Lab"
    Project     = "ImageMetadataAPI"
  }
}

# ----------------- FASE 3: API GATEWAY REST API -----------------

resource "aws_api_gateway_rest_api" "image_api" {
  name        = "ImageMetadataAPI"
  description = "REST API para carga y consulta de metadatos de imagenes"

  binary_media_types = ["image/jpeg", "*/*"]

  endpoint_configuration {
    types = ["REGIONAL"]
  }

  tags = {
    Environment = "Lab"
    Project     = "ImageMetadataAPI"
  }
}

# 1. Endpoint /upload (POST)
resource "aws_api_gateway_resource" "upload_res" {
  rest_api_id = aws_api_gateway_rest_api.image_api.id
  parent_id   = aws_api_gateway_rest_api.image_api.root_resource_id
  path_part   = "upload"
}

resource "aws_api_gateway_method" "upload_method" {
  rest_api_id   = aws_api_gateway_rest_api.image_api.id
  resource_id   = aws_api_gateway_resource.upload_res.id
  http_method   = "POST"
  authorization = "NONE"
}

resource "aws_api_gateway_integration" "upload_integration" {
  rest_api_id             = aws_api_gateway_rest_api.image_api.id
  resource_id             = aws_api_gateway_resource.upload_res.id
  http_method             = aws_api_gateway_method.upload_method.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.upload_image.invoke_arn
}

# 2. Endpoint /metadata/{image_id} (GET)
resource "aws_api_gateway_resource" "metadata_res" {
  rest_api_id = aws_api_gateway_rest_api.image_api.id
  parent_id   = aws_api_gateway_rest_api.image_api.root_resource_id
  path_part   = "metadata"
}

resource "aws_api_gateway_resource" "image_id_res" {
  rest_api_id = aws_api_gateway_rest_api.image_api.id
  parent_id   = aws_api_gateway_resource.metadata_res.id
  path_part   = "{image_id}"
}

resource "aws_api_gateway_method" "get_metadata_method" {
  rest_api_id   = aws_api_gateway_rest_api.image_api.id
  resource_id   = aws_api_gateway_resource.image_id_res.id
  http_method   = "GET"
  authorization = "NONE"

  request_parameters = {
    "method.request.path.image_id" = true
  }
}

resource "aws_api_gateway_integration" "get_metadata_integration" {
  rest_api_id             = aws_api_gateway_rest_api.image_api.id
  resource_id             = aws_api_gateway_resource.image_id_res.id
  http_method             = aws_api_gateway_method.get_metadata_method.http_method
  integration_http_method = "POST"
  type                    = "AWS_PROXY"
  uri                     = aws_lambda_function.get_image_metadata.invoke_arn
}

# Permisos Lambda para API Gateway
resource "aws_lambda_permission" "api_upload_permission" {
  statement_id  = "AllowAPIGatewayInvokeUpload"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.upload_image.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.image_api.execution_arn}/*/*"
}

resource "aws_lambda_permission" "api_get_permission" {
  statement_id  = "AllowAPIGatewayInvokeGetMetadata"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.get_image_metadata.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_api_gateway_rest_api.image_api.execution_arn}/*/*"
}

# Despliegue y Stage 'prod'
resource "aws_api_gateway_deployment" "api_deployment" {
  rest_api_id = aws_api_gateway_rest_api.image_api.id

  depends_on = [
    aws_api_gateway_integration.upload_integration,
    aws_api_gateway_integration.get_metadata_integration
  ]

  triggers = {
    redeployment = sha1(jsonencode([
      aws_api_gateway_resource.upload_res.id,
      aws_api_gateway_method.upload_method.id,
      aws_api_gateway_integration.upload_integration.id,
      aws_api_gateway_resource.metadata_res.id,
      aws_api_gateway_resource.image_id_res.id,
      aws_api_gateway_method.get_metadata_method.id,
      aws_api_gateway_integration.get_metadata_integration.id
    ]))
  }

  lifecycle {
    create_before_destroy = true
  }
}

resource "aws_api_gateway_stage" "prod_stage" {
  deployment_id = aws_api_gateway_deployment.api_deployment.id
  rest_api_id   = aws_api_gateway_rest_api.image_api.id
  stage_name    = "prod"
}

output "api_endpoint_url" {
  value = aws_api_gateway_stage.prod_stage.invoke_url
}
