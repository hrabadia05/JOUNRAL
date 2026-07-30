# Copy this file to terraform.tfvars and fill in real values.
# terraform.tfvars is NOT checked into version control (see .gitignore) because
# it will contain your Gemini API key once you fill it in.

# Required — no default, terraform apply will prompt for this if left unset.
gemini_api_key = "AQ.Ab8RN6L8NlKtalpOWAFNh262BYeVRjSglfXTq3pmwEZMl-Es7Q"

# Recommended for anything beyond local testing — lock this down to your
# actual frontend origin. Using ["*"] allows any website to call your API
# and load objects from your S3 bucket's CORS policy.
allowed_origins = ["*"]

# Optional overrides — defaults live in variables.tf, uncomment to change them.
# aws_region                = "us-west-1"
# project_name              = "trading-journal"
# environment               = "prod"
# gemini_model_id           = "gemini-3.6-flash"
# bedrock_fallback_model_id = "us.meta.llama4-scout-17b-instruct-v1:0"
#