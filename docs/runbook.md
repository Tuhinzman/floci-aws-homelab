# Floci AWS Homelab Runbook

This runbook explains how to build and validate the lab from start to finish. It is written for someone who is still learning Cloud DevOps or Platform Engineering and wants to understand what each step is proving.

The main rule is simple: do not call something successful only because a command exited with code `0`. Read the result back and verify it.

## 1. Lab environment

The reference lab uses:

```text
Ubuntu 24.04 LTS VM on Proxmox/KVM
6 vCPU
16 GiB RAM
80 GiB disk
Docker Engine and Docker Compose
Floci 1.7.0
AWS CLI v2
Terraform 1.16.0
Python 3.13 Lambda runtime containers
```

This is a practical starting point, not a hard minimum.

## 2. Check the VM first

Before installing anything, make sure the VM is healthy:

```bash
hostnamectl
lsblk
df -h /
ip route
systemctl is-active qemu-guest-agent
systemctl is-active fstrim.timer
```

You want working DNS, Internet access, SSH access, the expected disk size, and enough free storage.

## 3. Clone the repository

```bash
git clone https://github.com/Tuhinzman/floci-aws-homelab.git
cd floci-aws-homelab
```

Run the remaining commands from the repository root unless a section says otherwise.

## 4. Install Docker

```bash
sudo bash scripts/install-docker.sh
```

Check it:

```bash
docker --version
sudo docker compose version
sudo docker run --rm hello-world
```

Floci uses the Docker socket to launch container-backed services such as Lambda. Treat that socket as privileged access to the VM.

## 5. Configure and start Floci

Create the local environment file:

```bash
cp .env.example .env
nano .env
```

Example:

```text
FLOCI_HOST_IP=192.168.1.50
FLOCI_INTERNAL_HOSTNAME=floci
FLOCI_VERSION=1.7.0
FLOCI_REGION=us-east-1
```

The two addresses serve different purposes:

- `FLOCI_HOST_IP` is used by the VM shell and workstation.
- `FLOCI_INTERNAL_HOSTNAME=floci` is used by Lambda containers inside the Docker network.

Start Floci:

```bash
sudo docker compose --env-file .env -f compose/compose.yaml pull
sudo docker compose --env-file .env -f compose/compose.yaml up -d
```

Check status:

```bash
sudo docker compose --env-file .env -f compose/compose.yaml ps
```

Check health:

```bash
set -a
. ./.env
set +a
curl -fsS "http://${FLOCI_HOST_IP}:4566/_localstack/health"
```

Docker should also report the container as healthy:

```bash
sudo docker inspect floci \
  --format 'Status={{.State.Status}} Health={{.State.Health.Status}}'
```

## 6. Install and isolate AWS CLI

Install AWS CLI v2:

```bash
sudo bash scripts/install-aws-cli.sh
```

Create the local Floci profile as your normal Linux user:

```bash
bash scripts/configure-floci-cli.sh
```

Do not run the profile script through `sudo bash`. That changes `$HOME` and can make AWS CLI look for the profile under root instead of your user account.

Verify:

```bash
aws-floci sts get-caller-identity
```

Expected account:

```text
000000000000
```

The profile uses dummy credentials. Never put real AWS keys in it.

## 7. Validate the AWS-style services

Run the tests in order. Later tests reuse resources created by earlier ones.

### 7.1 Core services

```bash
bash scripts/smoke-test-core-services.sh
```

This checks STS, S3, SQS, DynamoDB, SSM Parameter Store, and Secrets Manager.

Expected final line:

```text
FLOCI_CORE_AWS_SMOKE_TEST=PASS
```

### 7.2 Core persistence

```bash
bash scripts/validate-persistence.sh
```

This restarts Floci and confirms that the previously created core resources can still be read.

Expected final line:

```text
FLOCI_PERSISTENCE_VALIDATION=PASS
```

### 7.3 Docker-backed Lambda

```bash
bash scripts/smoke-test-lambda.sh
```

This packages a Python 3.13 function, creates it through Floci, invokes it, checks the response, and verifies the real Lambda runtime container.

Expected final line:

```text
FLOCI_LAMBDA_SMOKE_TEST=PASS
```

### 7.4 SQS to Lambda to DynamoDB

```bash
bash scripts/smoke-test-sqs-lambda-dynamodb.sh
```

This checks the complete path:

```text
SQS message
→ event-source mapping
→ Docker-backed Lambda
→ DynamoDB write
→ exact item read-back
```

Expected final line:

```text
FLOCI_SQS_LAMBDA_DYNAMODB_TEST=PASS
```

### 7.5 Event chain after a Floci restart

```bash
bash scripts/validate-event-driven-persistence.sh
```

This restarts Floci, confirms that the queue, table, function, and mapping still exist, sends another message, and checks the new DynamoDB item.

Expected final line:

```text
FLOCI_EVENT_DRIVEN_PERSISTENCE_TEST=PASS
```

## 8. Terraform lifecycle

Terraform uses different resource names from the manual reference stack. This is important because the manual stack is used for persistence and reboot testing and must not be deleted by Terraform.

### 8.1 Install Terraform

```bash
sudo bash scripts/install-terraform.sh
terraform version
```

Validated version:

```text
Terraform v1.16.0
```

### 8.2 Create and validate the Terraform stack

On a clean Terraform state:

```bash
bash scripts/terraform-apply-validate.sh
```

The expected create plan is:

```text
6 to add
0 to change
0 to destroy
```

The six managed resources are:

```text
aws_dynamodb_table.orders
aws_iam_role.lambda
aws_iam_role_policy.lambda
aws_lambda_event_source_mapping.orders
aws_lambda_function.orders
aws_sqs_queue.orders
```

The script applies the saved plan, checks Terraform state, runs a no-change plan, sends an SQS message, verifies the Lambda execution, and reads the DynamoDB item back.

### 8.3 Resume validation if apply already succeeded

If the saved create plan has already been applied, do not rerun the initial six-create path just to recheck it.

Use:

```bash
bash scripts/terraform-resume-validate.sh
```

The reference lab passed:

```text
TERRAFORM_MANAGED_STATE_EXACT_MATCH=PASS
TERRAFORM_DATA_STATE_EXACT_MATCH=PASS
TERRAFORM_CONVERGENCE=PASS
TERRAFORM_EVENT_DRIVEN_FUNCTIONAL_TEST=PASS
FLOCI_TERRAFORM_RESUME_VALIDATION=PASS
```

Terraform data resources are checked separately from managed infrastructure.

### 8.4 Destroy and prove cleanup

Run destroy only when you intentionally want to remove the Terraform-managed stack:

```bash
bash scripts/terraform-destroy-verify.sh
```

The reference lab completed this successfully.

The destroy plan was exactly:

```text
0 to add
0 to change
6 to destroy
```

After applying the saved destroy plan, the following checks passed:

```text
TERRAFORM_MANAGED_STATE_EMPTY=PASS
SQS_QUEUE_ABSENT=PASS
DYNAMODB_TABLE_ABSENT=PASS
LAMBDA_FUNCTION_ABSENT=PASS
IAM_ROLE_ABSENT=PASS
EVENT_SOURCE_MAPPING_ABSENT=PASS
LAMBDA_RUNTIME_CONTAINER_ABSENT=PASS
```

Floci stayed healthy, and the manual reference stack was still present.

This means the Terraform lifecycle is now proven from exact create plan to exact destroy and remote absence checks.

## 9. Normal operations

Check status:

```bash
sudo docker compose --env-file .env -f compose/compose.yaml ps
```

View recent logs:

```bash
sudo docker compose --env-file .env -f compose/compose.yaml logs --tail=100 floci
```

List Floci and Lambda containers:

```bash
sudo docker ps \
  --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Networks}}'
```

Restart Floci:

```bash
sudo docker compose --env-file .env -f compose/compose.yaml restart floci
```

Stop and start the lab:

```bash
sudo docker compose --env-file .env -f compose/compose.yaml stop
sudo docker compose --env-file .env -f compose/compose.yaml start
```

Do not use `docker compose down -v` unless you deliberately want to delete the persistent Floci volume and its data.

## 10. Storage checks

Inside the VM:

```bash
df -h /
sudo docker system df
sudo docker volume ls
```

On the Proxmox host, also watch the LVM-thin data percentage. A thin-provisioned virtual disk can look large even when the physical pool has much less free space.

## 11. Network notes

Keep the VM address stable with a DHCP reservation if possible.

```text
VM shell or workstation → http://<FLOCI_HOST_IP>:4566
Lambda container        → http://floci:4566
```

If the VM address changes:

1. update `.env`
2. run `scripts/configure-floci-cli.sh` again
3. reconcile the Compose deployment
4. rerun the relevant validations

## 12. Common problems already encountered

The build uncovered several useful troubleshooting cases:

- SSH host-key warning after an IP address was reused
- AWS CLI installer failing because `unzip` was missing
- `sudo bash` losing the normal user's AWS profile
- a health check using `127.0.0.1` while port `4566` was bound to the VM address
- SQS URLs changing to `http://floci:4566` after enabling the internal hostname
- Terraform state validation accidentally counting data resources as managed resources
- Proxmox thin-pool over-provisioning warnings

See [troubleshooting.md](troubleshooting.md) for the fixes.

## 13. Security and public-repository rules

Keep these out of Git:

- `.env`
- Terraform state
- local `terraform.tfvars`
- saved Terraform plans
- raw evidence logs
- private IP addresses in evidence files
- SSH keys
- machine IDs
- real secrets or AWS credentials

The public repository should contain reusable configuration and sanitized validation records, not private lab state.

## 14. Current validation boundary

Verified:

```text
Core AWS-style workflows
Core persistence after Floci restart
Docker-backed Lambda
SQS → Lambda → DynamoDB
Event-chain processing after Floci restart
Terraform exact create plan
Terraform saved-plan apply
Terraform managed/data state validation
Terraform no-change convergence
Terraform functional event test
Terraform exact destroy plan
Terraform saved-plan destroy
Terraform managed state empty
Terraform API absence checks
Terraform Lambda container cleanup
Manual reference stack preserved
```

Not yet verified:

```text
Full Ubuntu VM reboot recovery
Full Proxmox host reboot recovery
Real AWS IAM behavior
Retry and DLQ parity
Exactly-once processing
Production scaling and availability
```

## 15. Next milestone

The next major test is a **full Ubuntu VM reboot**.

After the VM comes back, verify:

```text
Docker starts
→ Floci becomes healthy
→ manual SQS queue exists
→ manual DynamoDB table exists
→ manual Lambda function exists
→ manual event-source mapping is enabled
→ send a new SQS message
→ Lambda runs
→ new DynamoDB item is read back
```

That will close the remaining technical gate before the first stable portfolio release.
