output "floci_endpoint" {
  description = "Endpoint used by Terraform to reach Floci."
  value       = local.floci_endpoint
}

output "queue_name" {
  value = aws_sqs_queue.orders.name
}

output "queue_url" {
  value = aws_sqs_queue.orders.url
}

output "queue_arn" {
  value = aws_sqs_queue.orders.arn
}

output "dynamodb_table_name" {
  value = aws_dynamodb_table.orders.name
}

output "lambda_function_name" {
  value = aws_lambda_function.orders.function_name
}

output "lambda_function_arn" {
  value = aws_lambda_function.orders.arn
}

output "lambda_runtime_image" {
  value = "public.ecr.aws/lambda/python:${trimprefix(var.lambda_runtime, "python")}"
}

output "event_source_mapping_uuid" {
  value = aws_lambda_event_source_mapping.orders.uuid
}

output "iam_role_name" {
  value = aws_iam_role.lambda.name
}

output "iam_policy_name" {
  value = aws_iam_role_policy.lambda.name
}
