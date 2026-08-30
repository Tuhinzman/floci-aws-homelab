data "aws_iam_policy_document" "lambda_assume_role" {
  statement {
    effect  = "Allow"
    actions = ["sts:AssumeRole"]

    principals {
      type        = "Service"
      identifiers = ["lambda.amazonaws.com"]
    }
  }
}

resource "aws_dynamodb_table" "orders" {
  name         = var.dynamodb_table_name
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "order_id"

  attribute {
    name = "order_id"
    type = "S"
  }
}

resource "aws_sqs_queue" "orders" {
  name                       = local.queue_name
  visibility_timeout_seconds = 180
  message_retention_seconds  = 86400
}

resource "aws_iam_role" "lambda" {
  name               = local.role_name
  assume_role_policy = data.aws_iam_policy_document.lambda_assume_role.json
}

data "aws_iam_policy_document" "lambda_permissions" {
  statement {
    effect = "Allow"

    actions = [
      "sqs:ReceiveMessage",
      "sqs:DeleteMessage",
      "sqs:GetQueueAttributes",
    ]

    resources = [aws_sqs_queue.orders.arn]
  }

  statement {
    effect = "Allow"

    actions = [
      "dynamodb:PutItem",
      "dynamodb:GetItem",
    ]

    resources = [aws_dynamodb_table.orders.arn]
  }
}

resource "aws_iam_role_policy" "lambda" {
  name   = local.policy_name
  role   = aws_iam_role.lambda.id
  policy = data.aws_iam_policy_document.lambda_permissions.json
}

data "archive_file" "lambda" {
  type        = "zip"
  source_file = "${path.module}/lambda/lambda_function.py"
  output_path = "${path.module}/build/lambda_function.zip"
}

resource "aws_lambda_function" "orders" {
  function_name = local.function_name
  role          = aws_iam_role.lambda.arn
  runtime       = var.lambda_runtime
  handler       = "lambda_function.handler"

  filename         = data.archive_file.lambda.output_path
  source_code_hash = data.archive_file.lambda.output_base64sha256

  timeout     = 30
  memory_size = 128

  environment {
    variables = {
      TABLE_NAME         = aws_dynamodb_table.orders.name
      FLOCI_ENDPOINT_URL = local.internal_endpoint
    }
  }

  depends_on = [aws_iam_role_policy.lambda]
}

resource "aws_lambda_event_source_mapping" "orders" {
  event_source_arn = aws_sqs_queue.orders.arn
  function_name    = aws_lambda_function.orders.arn

  batch_size = 1
  enabled    = true
}
