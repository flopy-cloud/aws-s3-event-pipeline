output "bucket_name" {
  value = aws_s3_bucket.archivos.bucket
}

output "table_name" {
  value = aws_dynamodb_table.archivos.name
}

output "dlq_url" {
  value = aws_sqs_queue.dlq.url
}