##############################################
# Input variables
##############################################

variable "aws_region" {
  description = "AWS region to deploy into"
  type        = string
  default     = "us-west-1"
}

variable "project_name" {
  description = "Prefix used for naming all resources"
  type        = string
  default     = "trading-journal"
}

variable "environment" {
  description = "Deployment stage name (used for API Gateway stage + Lambda alias)"
  type        = string
  default     = "prod"
}

variable "allowed_origins" {
  description = "Origins allowed to call the HTTP API / S3 bucket (your hosted index.html origin). Use \"*\" only for local testing."
  type        = list(string)
  default     = ["*"]
}

variable "gemini_api_key" {
  description = "Google Gemini API key used by the journal Lambda for primary AI analysis"
  type        = string
  sensitive   = true
}

variable "bedrock_fallback_model_id" {
  description = "Bedrock model ID used as a fallback if Gemini fails or rate-limits. Uses a cross-region inference profile ('us.' prefix) since the underlying foundation model isn't hosted directly in every region."
  type        = string
  default     = "us.meta.llama4-scout-17b-instruct-v1:0"
}

variable "gemini_model_id" {
  description = "Gemini model ID for primary AI analysis"
  type        = string
  default     = "gemini-3.6-flash"
}
