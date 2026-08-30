locals {
  account_id        = "000000000000"
  floci_endpoint    = "http://${var.floci_host_ip}:4566"
  internal_endpoint = "http://${var.floci_internal_hostname}:4566"

  queue_name    = "${var.resource_prefix}-orders"
  function_name = "${var.resource_prefix}-orders-processor"
  role_name     = "${var.resource_prefix}-orders-role"
  policy_name   = "${var.resource_prefix}-orders-policy"
}
