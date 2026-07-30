##############################################
# Outputs
##############################################

output "cognito_user_pool_id" {
  value = aws_cognito_user_pool.main.id
}

output "cognito_user_pool_client_id" {
  value = aws_cognito_user_pool_client.main.id
}

output "http_api_url" {
  value = aws_apigatewayv2_stage.http_stage.invoke_url
}

output "websocket_api_url" {
  value = "wss://${aws_apigatewayv2_api.ws_api.id}.execute-api.${var.aws_region}.amazonaws.com/${aws_apigatewayv2_stage.ws_stage.name}"
}

output "s3_bucket_name" {
  value = aws_s3_bucket.charts.id
}

output "frontend_url" {
  description = "Secure public HTTPS URL of your frontend via CloudFront"
  value       = "https://${aws_cloudfront_distribution.cdn.domain_name}"
}

output "aws_region" {
  value = var.aws_region
}