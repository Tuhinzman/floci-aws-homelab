# Terraform Event-Driven Stack

This Terraform root module builds a separate event-driven stack inside Floci:

```text
SQS queue
→ Lambda event-source mapping
→ Docker-backed Python Lambda
→ DynamoDB table
```

The Terraform resource names are intentionally different from the manually created reference stack. That separation prevents Terraform from accidentally managing or deleting the resources used for the persistence and reboot tests.

## What Terraform manages

Terraform manages exactly six AWS-style resources:

1. DynamoDB table
2. SQS queue
3. IAM role
4. IAM inline policy
5. Lambda function
6. Lambda event-source mapping

The Lambda ZIP is built locally with the pinned `hashicorp/archive` provider.

## Before you start

Complete the main lab setup first. You should already have:

- Docker running
- Floci healthy
- AWS CLI configured with the local `floci` profile
- the repository `.env` file configured with the VM address

From the repository root, install the validated Terraform version:

```bash
sudo bash scripts/install-terraform.sh
terraform version
```

The reference lab was validated with Terraform `1.16.0`.

## Local Terraform variables

You normally do **not** need to edit `terraform.tfvars` by hand when using the repository lifecycle scripts.

The scripts read the existing repository `.env` file and generate the local ignored file:

```text
terraform/event-driven/terraform.tfvars
```

`terraform.tfvars`, Terraform state, saved plans, the provider cache, generated ZIP files, and raw evidence are local runtime files and must not be committed.

`terraform.tfvars.example` is included only as a reference for the expected variables.

## Recommended lifecycle

Run these commands from the repository root.

### 1. Create and validate the stack

```bash
bash scripts/terraform-apply-validate.sh
```

On a clean state, the expected plan is:

```text
6 to add
0 to change
0 to destroy
```

The script creates a saved plan, checks that the exact six expected resources will be created, applies that saved plan, and then validates the live event-driven workflow.

### 2. Resume validation after an interrupted post-apply check

If the saved create plan already applied successfully but a later validation step stopped, do not rerun the initial create workflow just to verify it again.

Use:

```bash
bash scripts/terraform-resume-validate.sh
```

This checks the existing Terraform state, verifies no-change convergence, sends a new SQS message, confirms the Lambda execution, and reads the expected DynamoDB item back without creating or destroying the stack.

### 3. Destroy the Terraform-managed stack

Only run this after the apply and functional validation are complete and you intentionally want to remove the Terraform-managed resources:

```bash
bash scripts/terraform-destroy-verify.sh
```

The destroy workflow checks the exact six-resource destroy plan before applying it. Afterward it verifies that managed Terraform state is empty and that the SQS queue, DynamoDB table, Lambda function, IAM role, event-source mapping, and Terraform Lambda runtime container are gone.

The manually created reference stack is separate and must remain untouched.

## Important safety notes

- Run the lifecycle scripts as your normal Linux user, not with `sudo bash`.
- Use `sudo` only where a script needs Docker access.
- Do not use real AWS credentials with this lab.
- Do not manually delete Terraform-managed resources during the lifecycle.
- Do not use `terraform state rm` as a substitute for a clean destroy.
- Do not remove the Floci Docker volume unless you intentionally want to delete the persistent lab data.
