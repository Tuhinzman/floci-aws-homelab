provider "aws" {
  region     = var.aws_region
  access_key = "test"
  secret_key = "test"

  skip_credentials_validation = true
  skip_metadata_api_check     = true
  skip_requesting_account_id  = true
  s3_use_path_style           = true

  endpoints {
    dynamodb = local.floci_endpoint
    iam      = local.floci_endpoint
    lambda   = local.floci_endpoint
    sqs      = local.floci_endpoint
    sts      = local.floci_endpoint
  }
}
