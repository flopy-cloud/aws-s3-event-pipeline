terraform {
  required_providers {
    aws     = { source = "hashicorp/aws", version = "~> 6.0" }
    archive = { source = "hashicorp/archive", version = "~> 2.0" }
    random  = { source = "hashicorp/random", version = "~> 3.0" }
  }
}

provider "aws" {
  region = var.region
}

# --- S3: bucket privado donde se suben los archivos ---
resource "random_id" "sufijo" {
  byte_length = 4
}

resource "aws_s3_bucket" "archivos" {
  bucket        = "event-pipeline-archivos-${random_id.sufijo.hex}"
  force_destroy = true
}

resource "aws_s3_bucket_public_access_block" "archivos" {
  bucket                  = aws_s3_bucket.archivos.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

# --- SQS: dead-letter queue y cola principal ---
resource "aws_sqs_queue" "dlq" {
  name                      = "event-pipeline-dlq"
  message_retention_seconds = 1209600 # 14 días
}

resource "aws_sqs_queue" "principal" {
  name                       = "event-pipeline-cola"
  visibility_timeout_seconds = 60

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.dlq.arn
    maxReceiveCount     = var.max_receive_count
  })
}

# Permite que S3 (solo este bucket) escriba en la cola
resource "aws_sqs_queue_policy" "principal" {
  queue_url = aws_sqs_queue.principal.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "s3.amazonaws.com" }
      Action    = "sqs:SendMessage"
      Resource  = aws_sqs_queue.principal.arn
      Condition = {
        ArnEquals = { "aws:SourceArn" = aws_s3_bucket.archivos.arn }
      }
    }]
  })
}

# S3 avisa a la cola cada vez que se sube un archivo
resource "aws_s3_bucket_notification" "archivos" {
  bucket = aws_s3_bucket.archivos.id

  queue {
    queue_arn = aws_sqs_queue.principal.arn
    events    = ["s3:ObjectCreated:*"]
  }

  depends_on = [aws_sqs_queue_policy.principal]
}

# --- DynamoDB: registro de archivos ---
resource "aws_dynamodb_table" "archivos" {
  name         = "event-pipeline-archivos"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "object_key"
  range_key    = "event_time"

  attribute {
    name = "object_key"
    type = "S"
  }

  attribute {
    name = "event_time"
    type = "S"
  }
}

# --- Rol de IAM con permisos mínimos ---
resource "aws_iam_role" "lambda" {
  name = "event-pipeline-lambda-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "lambda.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy" "lambda" {
  name = "event-pipeline-policy"
  role = aws_iam_role.lambda.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Effect   = "Allow"
        Action   = ["sqs:ReceiveMessage", "sqs:DeleteMessage", "sqs:GetQueueAttributes"]
        Resource = aws_sqs_queue.principal.arn
      },
      {
        Effect   = "Allow"
        Action   = ["dynamodb:PutItem"]
        Resource = aws_dynamodb_table.archivos.arn
      },
      {
        Effect   = "Allow"
        Action   = ["logs:CreateLogGroup", "logs:CreateLogStream", "logs:PutLogEvents"]
        Resource = "arn:aws:logs:*:*:*"
      }
    ]
  })
}

# --- Lambda ---
data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/lambda/lambda_function.py"
  output_path = "${path.module}/lambda.zip"
}

resource "aws_lambda_function" "procesador" {
  function_name    = "event-pipeline-procesador"
  role             = aws_iam_role.lambda.arn
  handler          = "lambda_function.lambda_handler"
  runtime          = "python3.13"
  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256
  timeout          = 10

  environment {
    variables = {
      TABLE_NAME = aws_dynamodb_table.archivos.name
    }
  }
}

# La cola dispara la Lambda
resource "aws_lambda_event_source_mapping" "sqs" {
  event_source_arn        = aws_sqs_queue.principal.arn
  function_name           = aws_lambda_function.procesador.arn
  batch_size              = 5
  function_response_types = ["ReportBatchItemFailures"]

  depends_on = [aws_iam_role_policy.lambda]
}