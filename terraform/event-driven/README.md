# Terraform Event-Driven Stack

This root module manages a separate event-driven stack inside Floci:

```text
SQS queue
→ Lambda event-source mapping
→ Docker-backed Python Lambda
→ DynamoDB table
```

The names intentionally differ from the manually validated resources so Terraform cannot adopt, replace, or delete the earlier evidence stack by accident.

## Managed resources

Terraform manages exactly six AWS-style resources:

1. DynamoDB table
2. SQS queue
3. IAM role
4. IAM inline policy
5. Lambda function
6. Lambda event-source mapping

The Lambda ZIP is generated locally with the official `hashicorp/archive` provider.

## Local configuration

Create `terraform.tfvars` from the example and set the private address of the Floci VM:

```bash
cp terraform.tfvars.example terraform.tfvars
nano terraform.tfvars
```

The local `terraform.tfvars`, Terraform state, saved plans, provider cache, and generated Lambda ZIP are ignored by Git.

## Recommended workflow

From the repository root:

```bash
sudo bash scripts/install-terraform.sh

bash scripts/terraform-apply-validate.sh

bash scripts/terraform-destroy-verify.sh
```

The apply script initializes Terraform, asserts the exact create plan, applies the saved plan, checks convergence, sends an SQS message, and asserts the resulting DynamoDB item.

The destroy script asserts the exact destroy plan, applies it, verifies empty Terraform state, and confirms the managed resources are absent from Floci.

Do not run the destroy script until the apply validation has passed and you have finished inspecting the Terraform-managed resources.
