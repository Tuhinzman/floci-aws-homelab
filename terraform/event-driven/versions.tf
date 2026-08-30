terraform {
  required_version = "~> 1.16.0"

  required_providers {
    archive = {
      source  = "hashicorp/archive"
      version = "2.8.0"
    }

    aws = {
      source  = "hashicorp/aws"
      version = "6.61.0"
    }
  }
}
