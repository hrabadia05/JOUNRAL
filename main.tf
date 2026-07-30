##############################################
# Trading Journal + Community Chat - main.tf
# Region: us-west-1
##############################################

terraform {
  required_version = ">= 1.5.0"
  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 5.40.0"
    }
    archive = {
      source  = "hashicorp/archive"
      version = ">= 2.4.0"
    }
    random = {
      source  = "hashicorp/random"
      version = ">= 3.6.0"
    }
  }
}

provider "aws" {
  region = var.aws_region
}

##############################################
# Random suffix for globally-unique names
##############################################

resource "random_id" "suffix" {
  byte_length = 4
}

locals {
  name_suffix     = random_id.suffix.hex
  bucket_name     = "${var.project_name}-charts-${local.name_suffix}"
  http_api_name   = "${var.project_name}-http-api"
  ws_api_name     = "${var.project_name}-ws-api"
  lambda_runtime  = "nodejs20.x"
}

data "aws_caller_identity" "current" {}

##############################################
# 1. Cognito User Pool + Client
##############################################

resource "aws_cognito_user_pool" "main" {
  name                     = "${var.project_name}-user-pool"
  username_attributes      = ["email"]
  auto_verified_attributes = ["email"]

  password_policy {
    minimum_length    = 8
    require_lowercase = true
    require_uppercase = true
    require_numbers   = true
    require_symbols   = false
  }

  account_recovery_setting {
    recovery_mechanism {
      name     = "verified_email"
      priority = 1
    }
  }

  schema {
    name                = "email"
    attribute_data_type = "String"
    required            = true
    mutable             = true
    string_attribute_constraints {
      min_length = 5
      max_length = 256
    }
  }

  admin_create_user_config {
    allow_admin_create_user_only = false
  }

  verification_message_template {
    default_email_option = "CONFIRM_WITH_CODE"
  }
}

resource "aws_cognito_user_pool_client" "main" {
  name         = "${var.project_name}-client"
  user_pool_id = aws_cognito_user_pool.main.id

  generate_secret = false

  explicit_auth_flows = [
    "ALLOW_USER_PASSWORD_AUTH",
    "ALLOW_USER_SRP_AUTH",
    "ALLOW_REFRESH_TOKEN_AUTH",
  ]

  prevent_user_existence_errors = "ENABLED"

  access_token_validity  = 1
  id_token_validity      = 1
  refresh_token_validity = 30

  token_validity_units {
    access_token  = "hours"
    id_token      = "hours"
    refresh_token = "days"
  }
}

##############################################
# 2. DynamoDB Tables
##############################################

resource "aws_dynamodb_table" "journal_entries" {
  name         = "${var.project_name}-JournalEntries"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "UserId"
  range_key    = "SortKey"

  attribute {
    name = "UserId"
    type = "S"
  }

  attribute {
    name = "SortKey"
    type = "S"
  }
}

resource "aws_dynamodb_table" "chat_connections" {
  name         = "${var.project_name}-ChatConnections"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "ConnectionId"

  attribute {
    name = "ConnectionId"
    type = "S"
  }
}

resource "aws_dynamodb_table" "chat_messages" {
  name         = "${var.project_name}-ChatMessages"
  billing_mode = "PAY_PER_REQUEST"
  hash_key     = "RoomId"
  range_key    = "Timestamp"

  attribute {
    name = "RoomId"
    type = "S"
  }

  attribute {
    name = "Timestamp"
    type = "N"
  }
}

##############################################
# 3. S3 Bucket for chart screenshots
##############################################

resource "aws_s3_bucket" "charts" {
  bucket = local.bucket_name
}

resource "aws_s3_bucket_public_access_block" "charts" {
  bucket                  = aws_s3_bucket.charts.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "charts" {
  bucket = aws_s3_bucket.charts.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

resource "aws_s3_bucket_server_side_encryption_configuration" "charts" {
  bucket = aws_s3_bucket.charts.id
  rule {
    apply_server_side_encryption_by_default {
      sse_algorithm = "AES256"
    }
  }
}

resource "aws_s3_bucket_cors_configuration" "charts" {
  bucket = aws_s3_bucket.charts.id

  cors_rule {
    allowed_headers = ["*"]
    allowed_methods = ["GET", "PUT", "POST", "HEAD"]
    allowed_origins = var.allowed_origins
    expose_headers  = ["ETag"]
    max_age_seconds = 3000
  }
}

##############################################
# 3b. S3 Bucket for frontend static hosting
#     (Strictly Private, accessed only via CloudFront OAC)
##############################################

resource "aws_s3_bucket" "frontend" {
  bucket = "${var.project_name}-frontend-${local.name_suffix}"
}

resource "aws_s3_bucket_public_access_block" "frontend" {
  bucket                  = aws_s3_bucket.frontend.id
  block_public_acls       = true
  block_public_policy     = true
  ignore_public_acls      = true
  restrict_public_buckets = true
}

resource "aws_s3_bucket_ownership_controls" "frontend" {
  bucket = aws_s3_bucket.frontend.id
  rule {
    object_ownership = "BucketOwnerEnforced"
  }
}

# Renders index.html.tftpl with real Cognito/API values baked in, then uploads it
resource "aws_s3_object" "frontend_index" {
  bucket       = aws_s3_bucket.frontend.id
  key          = "index.html"
  content_type = "text/html"

  content = templatefile("${path.module}/index.html.tftpl", {
    aws_region           = var.aws_region
    cognito_user_pool_id = aws_cognito_user_pool.main.id
    cognito_client_id    = aws_cognito_user_pool_client.main.id
    http_api_url         = aws_apigatewayv2_stage.http_stage.invoke_url
    websocket_api_url    = "wss://${aws_apigatewayv2_api.ws_api.id}.execute-api.${var.aws_region}.amazonaws.com/${aws_apigatewayv2_stage.ws_stage.name}"
  })
}

##############################################
# 3c. CloudFront CDN & Origin Access Control (OAC)
##############################################

resource "aws_cloudfront_origin_access_control" "oac" {
  name                              = "${var.project_name}-oac-${local.name_suffix}"
  description                       = "OAC for Private Frontend S3 Bucket"
  origin_access_control_origin_type = "s3"
  signing_behavior                  = "always"
  signing_protocol                  = "sigv4"
}

resource "aws_cloudfront_distribution" "cdn" {
  enabled             = true
  is_ipv6_enabled     = true
  default_root_object = "index.html"

  origin {
    domain_name              = aws_s3_bucket.frontend.bucket_regional_domain_name
    origin_id                = "S3-FrontendOrigin"
    origin_access_control_id = aws_cloudfront_origin_access_control.oac.id
  }

  default_cache_behavior {
    target_origin_id       = "S3-FrontendOrigin"
    viewer_protocol_policy = "redirect-to-https"
    allowed_methods        = ["GET", "HEAD"]
    cached_methods         = ["GET", "HEAD"]
    cache_policy_id        = "658327ea-f89d-4fab-a63d-7e88639e58f3" # Managed CachingOptimized
  }

  restrictions {
    geo_restriction {
      restriction_type = "none"
    }
  }

  viewer_certificate {
    cloudfront_default_certificate = true
  }
}

resource "aws_s3_bucket_policy" "oac_policy" {
  bucket = aws_s3_bucket.frontend.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "AllowCloudFrontServicePrincipal"
        Effect = "Allow"
        Principal = {
          Service = "cloudfront.amazonaws.com"
        }
        Action   = "s3:GetObject"
        Resource = "${aws_s3_bucket.frontend.arn}/*"
        Condition = {
          StringEquals = {
            "AWS:SourceArn" = aws_cloudfront_distribution.cdn.arn
          }
        }
      }
    ]
  })
}

##############################################
# 4. IAM Roles & Permissions for Lambda
##############################################

resource "aws_iam_role" "lambda_exec" {
  name = "${var.project_name}-lambda-exec-role"

  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Action = "sts:AssumeRole"
      Effect = "Allow"
      Principal = {
        Service = "lambda.amazonaws.com"
      }
    }]
  })
}

resource "aws_iam_role_policy_attachment" "lambda_basic_logs" {
  role       = aws_iam_role.lambda_exec.name
  policy_arn = "arn:aws:iam::aws:policy/service-role/AWSLambdaBasicExecutionRole"
}

resource "aws_iam_role_policy" "lambda_permissions" {
  name = "${var.project_name}-lambda-permissions"
  role = aws_iam_role.lambda_exec.id

  policy = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid    = "DynamoDBAccess"
        Effect = "Allow"
        Action = [
          "dynamodb:PutItem",
          "dynamodb:GetItem",
          "dynamodb:Query",
          "dynamodb:Scan",
          "dynamodb:DeleteItem",
          "dynamodb:UpdateItem",
        ]
        Resource = [
          aws_dynamodb_table.journal_entries.arn,
          "${aws_dynamodb_table.journal_entries.arn}/index/*",
          aws_dynamodb_table.chat_connections.arn,
          aws_dynamodb_table.chat_messages.arn,
          "${aws_dynamodb_table.chat_messages.arn}/index/*",
        ]
      },
      {
        Sid    = "S3Access"
        Effect = "Allow"
        Action = [
          "s3:PutObject",
          "s3:GetObject",
        ]
        Resource = "${aws_s3_bucket.charts.arn}/*"
      },
      {
        Sid      = "BedrockAccess"
        Effect   = "Allow"
        Action   = ["bedrock:InvokeModel"]
        Resource = [
          "arn:aws:bedrock:${var.aws_region}:${data.aws_caller_identity.current.account_id}:inference-profile/${var.bedrock_fallback_model_id}",
          "arn:aws:bedrock:us-east-1::foundation-model/*",
          "arn:aws:bedrock:us-east-2::foundation-model/*",
          "arn:aws:bedrock:us-west-2::foundation-model/*",
        ]
      },
      {
        Sid      = "CognitoGetUser"
        Effect   = "Allow"
        Action   = ["cognito-idp:GetUser"]
        Resource = aws_cognito_user_pool.main.arn
      },
      {
        Sid      = "WebSocketManageConnections"
        Effect   = "Allow"
        Action   = ["execute-api:ManageConnections"]
        Resource = "arn:aws:execute-api:${var.aws_region}:${data.aws_caller_identity.current.account_id}:*/*/POST/@connections/*"
      },
    ]
  })
}

##############################################
# 5. Lambda packaging (npm install + zip)
##############################################

resource "null_resource" "npm_install" {
  triggers = {
    package_json_hash = filesha256("${path.module}/src/package.json")
  }

  provisioner "local-exec" {
    command = "cd ${path.module}/src && npm install --omit=dev"
  }
}

data "archive_file" "journal_handler_zip" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/builds/journal-handler.zip"
  excludes    = ["chat-handler.mjs"]

  depends_on = [null_resource.npm_install]
}

data "archive_file" "chat_handler_zip" {
  type        = "zip"
  source_dir  = "${path.module}/src"
  output_path = "${path.module}/builds/chat-handler.zip"
  excludes    = ["journal-handler.mjs"]

  depends_on = [null_resource.npm_install]
}

##############################################
# 6. Lambda Functions
##############################################

resource "aws_lambda_function" "journal_handler" {
  function_name    = "${var.project_name}-journal-handler"
  role             = aws_iam_role.lambda_exec.arn
  runtime          = local.lambda_runtime
  handler          = "journal-handler.handler"
  filename         = data.archive_file.journal_handler_zip.output_path
  source_code_hash = data.archive_file.journal_handler_zip.output_base64sha256
  timeout          = 30
  memory_size      = 512

  environment {
    variables = {
      JOURNAL_TABLE    = aws_dynamodb_table.journal_entries.name
      BUCKET_NAME      = aws_s3_bucket.charts.id
      GEMINI_API_KEY   = var.gemini_api_key
      GEMINI_MODEL_ID  = var.gemini_model_id
      BEDROCK_MODEL_ID = var.bedrock_fallback_model_id
      AWS_REGION_NAME  = var.aws_region
    }
  }
}

resource "aws_lambda_function" "chat_handler" {
  function_name    = "${var.project_name}-chat-handler"
  role             = aws_iam_role.lambda_exec.arn
  runtime          = local.lambda_runtime
  handler          = "chat-handler.handler"
  filename         = data.archive_file.chat_handler_zip.output_path
  source_code_hash = data.archive_file.chat_handler_zip.output_base64sha256
  timeout          = 15
  memory_size      = 256

  environment {
    variables = {
      CONNECTIONS_TABLE = aws_dynamodb_table.chat_connections.name
      MESSAGES_TABLE    = aws_dynamodb_table.chat_messages.name
    }
  }
}

##############################################
# 7. HTTP API (REST journal endpoints)
##############################################

resource "aws_apigatewayv2_api" "http_api" {
  name          = local.http_api_name
  protocol_type = "HTTP"

  cors_configuration {
    allow_origins = var.allowed_origins
    allow_methods = ["GET", "POST", "PUT", "DELETE", "OPTIONS"]
    allow_headers = ["Content-Type", "Authorization"]
  }
}

resource "aws_apigatewayv2_authorizer" "cognito" {
  api_id           = aws_apigatewayv2_api.http_api.id
  authorizer_type  = "JWT"
  identity_sources = ["$request.header.Authorization"]
  name             = "${var.project_name}-cognito-authorizer"

  jwt_configuration {
    audience = [aws_cognito_user_pool_client.main.id]
    issuer   = "https://cognito-idp.${var.aws_region}.amazonaws.com/${aws_cognito_user_pool.main.id}"
  }
}

resource "aws_apigatewayv2_integration" "journal_lambda" {
  api_id                 = aws_apigatewayv2_api.http_api.id
  integration_type       = "AWS_PROXY"
  integration_uri        = aws_lambda_function.journal_handler.invoke_arn
  payload_format_version = "2.0"
}

resource "aws_apigatewayv2_route" "post_journal" {
  api_id             = aws_apigatewayv2_api.http_api.id
  route_key          = "POST /journal"
  target             = "integrations/${aws_apigatewayv2_integration.journal_lambda.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_apigatewayv2_route" "get_journal" {
  api_id             = aws_apigatewayv2_api.http_api.id
  route_key          = "GET /journal"
  target             = "integrations/${aws_apigatewayv2_integration.journal_lambda.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_apigatewayv2_route" "put_journal" {
  api_id             = aws_apigatewayv2_api.http_api.id
  route_key          = "PUT /journal"
  target             = "integrations/${aws_apigatewayv2_integration.journal_lambda.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_apigatewayv2_route" "delete_journal" {
  api_id             = aws_apigatewayv2_api.http_api.id
  route_key          = "DELETE /journal"
  target             = "integrations/${aws_apigatewayv2_integration.journal_lambda.id}"
  authorization_type = "JWT"
  authorizer_id      = aws_apigatewayv2_authorizer.cognito.id
}

resource "aws_apigatewayv2_stage" "http_stage" {
  api_id      = aws_apigatewayv2_api.http_api.id
  name        = "$default"
  auto_deploy = true
}

resource "aws_lambda_permission" "http_api_invoke" {
  statement_id  = "AllowHTTPAPIInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.journal_handler.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.http_api.execution_arn}/*/*"
}

##############################################
# 8. WebSocket API (Real-time chat)
##############################################

resource "aws_apigatewayv2_api" "ws_api" {
  name                       = local.ws_api_name
  protocol_type              = "WEBSOCKET"
  route_selection_expression = "$request.body.action"
}

resource "aws_apigatewayv2_integration" "chat_lambda" {
  api_id                    = aws_apigatewayv2_api.ws_api.id
  integration_type          = "AWS_PROXY"
  integration_uri           = aws_lambda_function.chat_handler.invoke_arn
  content_handling_strategy = "CONVERT_TO_TEXT"
}

resource "aws_apigatewayv2_route" "connect" {
  api_id    = aws_apigatewayv2_api.ws_api.id
  route_key = "$connect"
  target    = "integrations/${aws_apigatewayv2_integration.chat_lambda.id}"
}

resource "aws_apigatewayv2_route" "disconnect" {
  api_id    = aws_apigatewayv2_api.ws_api.id
  route_key = "$disconnect"
  target    = "integrations/${aws_apigatewayv2_integration.chat_lambda.id}"
}

resource "aws_apigatewayv2_route" "send_message" {
  api_id    = aws_apigatewayv2_api.ws_api.id
  route_key = "sendMessage"
  target    = "integrations/${aws_apigatewayv2_integration.chat_lambda.id}"
}

resource "aws_apigatewayv2_route" "get_chat_history" {
  api_id    = aws_apigatewayv2_api.ws_api.id
  route_key = "getChatHistory"
  target    = "integrations/${aws_apigatewayv2_integration.chat_lambda.id}"
}

resource "aws_apigatewayv2_stage" "ws_stage" {
  api_id      = aws_apigatewayv2_api.ws_api.id
  name        = var.environment
  auto_deploy = true
}

resource "aws_lambda_permission" "ws_api_invoke" {
  statement_id  = "AllowWebSocketAPIInvoke"
  action        = "lambda:InvokeFunction"
  function_name = aws_lambda_function.chat_handler.function_name
  principal     = "apigateway.amazonaws.com"
  source_arn    = "${aws_apigatewayv2_api.ws_api.execution_arn}/*/*"
}