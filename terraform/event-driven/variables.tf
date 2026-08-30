variable "floci_host_ip" {
  description = "Private IP address used by Terraform and the VM shell to reach Floci."
  type        = string

  validation {
    condition     = length(trimspace(var.floci_host_ip)) > 0
    error_message = "floci_host_ip must not be empty."
  }
}

variable "floci_internal_hostname" {
  description = "Docker-network hostname used by Lambda runtime containers to reach Floci."
  type        = string
  default     = "floci"

  validation {
    condition     = length(trimspace(var.floci_internal_hostname)) > 0
    error_message = "floci_internal_hostname must not be empty."
  }
}

variable "aws_region" {
  description = "AWS-style region used by the local emulator."
  type        = string
  default     = "us-east-1"
}

variable "resource_prefix" {
  description = "Prefix used for the Terraform-managed queue, Lambda function, and IAM resources."
  type        = string
  default     = "floci-terraform"

  validation {
    condition = (
      length(var.resource_prefix) >= 3 &&
      length(var.resource_prefix) <= 32 &&
      can(regex("^[a-z0-9-]+$", var.resource_prefix))
    )
    error_message = "resource_prefix must contain 3-32 lowercase letters, numbers, or hyphens."
  }
}

variable "dynamodb_table_name" {
  description = "Name of the Terraform-managed DynamoDB table."
  type        = string
  default     = "FlociTerraformOrders"
}

variable "lambda_runtime" {
  description = "Lambda runtime used by the event processor."
  type        = string
  default     = "python3.13"
}
