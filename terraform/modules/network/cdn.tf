variable "project" {
  default = "fakecompany"
}

variable "environment" {
  default = "prod"
}

variable "account_number" {
  type = string
}

variable "queue_integration_uri" {
  type = string
}

variable "queue_integration_name" {
  type = string
}

locals {
  standard_tags = {
    project     = var.project,
    environment = var.environment
  }

  env = terraform.workspace
}

/* This is the gateway to the queue lambda */
resource "aws_apigatewayv2_api" "fakecompany_api_gateway" {
  name          = "fakecompany_api_gateway"
  protocol_type = "HTTP"
}

/* ... and this is the integration from the gateweay to the lambda */
resource "aws_apigatewayv2_integration" "fakecompany_api_integration" {
  api_id           = aws_apigatewayv2_api.fakecompany_api_gateway.id
  integration_type = "AWS_PROXY"

  connection_type      = "INTERNET"
  description          = "fakecompany queue data endpoint"
  integration_method   = "POST"
  integration_uri      = var.queue_integration_uri
  passthrough_behavior = "WHEN_NO_MATCH"
}

/* Add the POST route to the gateway at /api/save */
resource "aws_apigatewayv2_route" "fakecompany_api_route" {
  api_id = aws_apigatewayv2_api.fakecompany_api_gateway.id
  /* 'save' is a bad name; in Real Life, this would reflect the model to save, such as 'car' or 'widget': */
  route_key = "POST /api/save"

  target = "integrations/${aws_apigatewayv2_integration.fakecompany_api_integration.id}"
}

/* Create a "Prod" deployment */
resource "aws_apigatewayv2_deployment" "fakecompany_api_deployment" {
  depends_on  = [aws_apigatewayv2_route.fakecompany_api_route]
  api_id      = aws_apigatewayv2_route.fakecompany_api_route.api_id
  description = "fakecompany API"

  triggers = {
    redeployment = sha1(join(",", tolist([
      jsonencode(aws_apigatewayv2_integration.fakecompany_api_integration),
      jsonencode(aws_apigatewayv2_route.fakecompany_api_route),
    ])))
  }

  lifecycle {
    create_before_destroy = true
  }
}

/* Add a log group for the gateway; the stage will log to this group */
resource "aws_cloudwatch_log_group" "fakecompany_api_gateway" {
  name = "/aws/APIGateway/${aws_apigatewayv2_api.fakecompany_api_gateway.name}"

  retention_in_days = 30
}

/* create a 'prod' stage */
/* The URL will end up being https://abcdefg.execute-api.us-east-2.amazonaws.com/prod/api/save */
resource "aws_apigatewayv2_stage" "fakecompany_api_stage" {
  api_id      = aws_apigatewayv2_api.fakecompany_api_gateway.id
  name        = local.env
  auto_deploy = true

  access_log_settings {
    destination_arn = aws_cloudwatch_log_group.fakecompany_api_gateway.arn
    format = jsonencode({
      requestId      = "$context.requestId"
      httpMethod     = "$context.httpMethod"
      status         = "$context.status"
      sourceIp       = "$context.identity.sourceIp"
      requestTime    = "$context.requestTime"
      protocol       = "$context.protocol"
      resourcePath   = "$context.resourcePath"
      routeKey       = "$context.routeKey"
      responseLength = "$context.responseLength"

      integrationErrorMessage = "$context.integrationErrorMessage"
    })
  }
}

/* Ensure the gateway can trigger the lambda */
resource "aws_lambda_permission" "fakecompany_api_gateway_lambda" {
  statement_id  = "AllowExecutionFromAPIGateway"
  action        = "lambda:InvokeFunction"
  function_name = var.queue_integration_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.fakecompany_api_gateway.execution_arn}/*/*/api/save"
}

resource "aws_cloudfront_distribution" "fakecompany_api_distribution" {
  depends_on = [aws_apigatewayv2_deployment.fakecompany_api_deployment]
  origin {
    domain_name = replace(aws_apigatewayv2_api.fakecompany_api_gateway.api_endpoint, "/^https?://([^/]*).*/", "$1")
    origin_id   = "fakecompany_api_gateway"
    origin_path = "/prod"

    custom_origin_config {
      http_port              = 80
      https_port             = 443
      origin_protocol_policy = "https-only"
      origin_ssl_protocols   = ["TLSv1.2"]
    }
  }

  enabled         = true
  is_ipv6_enabled = true
  comment         = "Managed by Terraform"

  default_cache_behavior {
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["HEAD", "GET"]
    target_origin_id = "fakecompany_api_gateway"

    forwarded_values {
      query_string = true
      cookies {
        forward = "all"
      }
    }

    viewer_protocol_policy = "allow-all"
    min_ttl                = 0
    default_ttl            = 0
    max_ttl                = 0
  }

  ordered_cache_behavior {
    path_pattern     = "/api/*"
    allowed_methods  = ["DELETE", "GET", "HEAD", "OPTIONS", "PATCH", "POST", "PUT"]
    cached_methods   = ["HEAD", "GET"]
    target_origin_id = "fakecompany_api_gateway"

    default_ttl = 0
    min_ttl     = 0
    max_ttl     = 0

    forwarded_values {
      query_string = true
      cookies {
        forward = "none"
      }
    }

    viewer_protocol_policy = "redirect-to-https"
  }

  // NA and Europe
  price_class = "PriceClass_100"

  restrictions {
    geo_restriction {
      restriction_type = "whitelist"
      locations        = ["US", "CA", "GB", "DE"]
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }

  tags = merge(local.standard_tags, {
    description = "fakecompany CloudFront distribution. Managed by Terraform."
  })
}
