variable "project" {
  default = "fakecompany"
}

variable "environment" {
  default = "prod"
}

variable "account_number" {
  type = string
}

locals {
  standard_tags = {
    project     = var.project,
    environment = var.environment
  }

  env = terraform.workspace
}

terraform {
  required_providers {
    aws = {
      source = "hashicorp/aws"
    }
  }
}

// Lambda role with lambda permissions for each lambda:
resource "aws_iam_role" "fakecompany_queue_role" {
  name = "fakecompany-queue-role"

  assume_role_policy = jsonencode({
    Version : "2012-10-17",
    Statement : [{
      Action : "sts:AssumeRole",
      Principal : {
        Service : "lambda.amazonaws.com"
      },
      Effect : "Allow",
    }]
  })
}

resource "aws_iam_role" "fakecompany_persist_role" {
  name = "fakecompany-persist-role"

  assume_role_policy = jsonencode({
    Version : "2012-10-17",
    Statement : [{
      Action : "sts:AssumeRole",
      Principal : {
        Service : "lambda.amazonaws.com"
      },
      Effect : "Allow",
    }]
  })
}

/* Deadletter queue for exceptions: */
resource "aws_sqs_queue" "fakecompany_data_dlq" {
  name = "fakecompany-data-dlq"
  tags = local.standard_tags
}

/* Queue to save data from the fakecompany_queue_data lambda */
resource "aws_sqs_queue" "fakecompany_data" {
  name = "fakecompany-data"

  redrive_policy = jsonencode({
    deadLetterTargetArn = aws_sqs_queue.fakecompany_data_dlq.arn
    maxReceiveCount     = 5
  })

  tags = local.standard_tags
}

/* Policy to write data to the fakecompany data queue: */
data "aws_iam_policy_document" "fakecompany_queue_sqs_access" {
  statement {
    effect = "Allow"
    actions = [
      "sqs:SendMessage",
    ]
    resources = [
      aws_sqs_queue.fakecompany_data.arn
    ]
  }
}

/* Policy to read data from the fakecompany data queue, plus DLQ: */
data "aws_iam_policy_document" "fakecompany_persist_sqs_access" {
  statement {
    effect = "Allow"
    actions = [
      "sqs:ReceiveMessage",
      "sqs:SendMessage",
      "sqs:GetQueueAttributes",
      "sqs:DeleteMessage"
    ]
    resources = [
      aws_sqs_queue.fakecompany_data.arn,
      aws_sqs_queue.fakecompany_data_dlq.arn
    ]
  }
}

/* Policy to read/write data to the fakecompany data store: */
data "aws_iam_policy_document" "fakecompany_persist_dynamo_access" {
  statement {
    effect = "Allow"
    actions = [
      "dynamodb:PutItem",
    ]
    resources = [
      aws_dynamodb_table.fakecompany_dynamo.arn,
    ]
  }
}

/* Policy for lambda logging; since the log groups are managed here */
data "aws_iam_policy_document" "fakecompany_lambda_logging" {
  statement {
    effect = "Allow"
    actions = [
      /* CreateLogGroup not needed; it's managed in terraform */
      "logs:CreateLogStream",
      "logs:PutLogEvents"
    ]
    resources = ["arn:aws:logs:*:*:*"]
  }
}

/* Attach SQS policy to the queue role */
resource "aws_iam_role_policy" "fakecompany_queue_sqs_access" {
  name   = "fakecompany-queue-sqs-role-policy"
  role   = aws_iam_role.fakecompany_queue_role.id
  policy = data.aws_iam_policy_document.fakecompany_queue_sqs_access.json
}

/* Attach SQS policy to the persist role */
resource "aws_iam_role_policy" "fakecompany_persist_sqs_access" {
  name   = "fakecompany-persist-sqs-role-policy"
  role   = aws_iam_role.fakecompany_persist_role.id
  policy = data.aws_iam_policy_document.fakecompany_persist_sqs_access.json
}

/* Attach logging policy to role */
resource "aws_iam_role_policy" "fakecompany_queue_log_access" {
  name   = "fakecompany-queue-log-role-policy"
  role   = aws_iam_role.fakecompany_queue_role.id
  policy = data.aws_iam_policy_document.fakecompany_lambda_logging.json
}

resource "aws_iam_role_policy" "fakecompany_persis_log_access" {
  name   = "fakecompany-persist-log-role-policy"
  role   = aws_iam_role.fakecompany_persist_role.id
  policy = data.aws_iam_policy_document.fakecompany_lambda_logging.json
}

/* Attach persistence policy to the role */
resource "aws_iam_role_policy" "fakecompany_persist_dynamo_access" {
  name   = "fakecompany-perist-dynamo-role-policy"
  role   = aws_iam_role.fakecompany_persist_role.id
  policy = data.aws_iam_policy_document.fakecompany_persist_dynamo_access.json
}

/* Create the queue data log group */
resource "aws_cloudwatch_log_group" "fakecompany_queue_data_logs" {
  name              = "/aws/lambda/fakecompany-queue-data"
  retention_in_days = 30
  tags              = local.standard_tags
}

/* Create the queue data lambda */
resource "aws_lambda_function" "fakecompany_queue_data" {
  depends_on = [
    aws_iam_role.fakecompany_queue_role
  ]
  description      = "Function to queue data for later processing."
  function_name    = "fakecompany-queue-data"
  role             = aws_iam_role.fakecompany_queue_role.arn
  handler          = "lambdas/fakecompany-queue-data.handler"
  publish          = true
  runtime          = "nodejs12.x"
  timeout          = 30
  memory_size      = 128
  filename         = "../fakecompany-queue-data.zip"
  source_code_hash = filebase64sha256("../fakecompany-queue-data.zip")

  environment {
    variables = {
      ACCOUNT_NUMBER = var.account_number
    }
  }

  lifecycle {
    prevent_destroy = true
  }

  tags = local.standard_tags
}

/* The integration URI and name are used by the API Gateway resources */
output "queue_integration_uri" {
  value = aws_lambda_function.fakecompany_queue_data.invoke_arn
}

output "queue_integration_name" {
  value = aws_lambda_function.fakecompany_queue_data.function_name
}

/* Log group for the persistence lambda */
resource "aws_cloudwatch_log_group" "fakecompany_persist_data_logs" {
  name              = "/aws/lambda/fakecompany-persist-data"
  retention_in_days = 30
  tags              = local.standard_tags
}

/* Create the persistence lambda which will be tied to an SQS trigger */
resource "aws_lambda_function" "fakecompany_persist_data" {
  depends_on = [
    aws_iam_role.fakecompany_persist_role
  ]
  description      = "Function to persist data from a queue."
  function_name    = "fakecompany-persist-data"
  role             = aws_iam_role.fakecompany_persist_role.arn
  handler          = "lambdas/fakecompany-persist-data.handler"
  publish          = true
  runtime          = "nodejs12.x"
  timeout          = 30
  memory_size      = 128
  filename         = "../fakecompany-persist-data.zip"
  source_code_hash = filebase64sha256("../fakecompany-persist-data.zip")

  environment {
    variables = {
      ACCOUNT_NUMBER = var.account_number
    }
  }

  lifecycle {
    prevent_destroy = true
  }

  tags = local.standard_tags
}

// Trigger persist data on enqueued messages
resource "aws_lambda_event_source_mapping" "fakecompany_persist_data_event" {
  event_source_arn = aws_sqs_queue.fakecompany_data.arn
  enabled          = true
  function_name    = aws_lambda_function.fakecompany_persist_data.arn
  batch_size       = 1
}

/* Simple persitence storage used by the fakecompany-persist-data lambda */
resource "aws_dynamodb_table" "fakecompany_dynamo" {
  name           = "fakecompany"
  read_capacity  = 1
  write_capacity = 1
  hash_key       = "messageId"
  range_key      = "createdAt"

  attribute {
    name = "messageId"
    type = "S"
  }

  attribute {
    name = "createdAt"
    type = "S"
  }

  tags = local.standard_tags

  lifecycle {
    prevent_destroy = true
  }
}
