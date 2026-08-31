# Floci AWS Homelab Runbook

This runbook explains how to build, operate, and validate the Floci AWS homelab. It is written for learners who want practical Cloud DevOps or Platform Engineering experience without leaving billable AWS resources running while they experiment.

The lab favors simple commands and observable checks. A service is only listed as verified after a real workflow has been executed and its result has been read back.

## 1. Validated environment

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

This is a practical starting size, not a minimum. Heavier services may need more memory and disk.

When Proxmox uses thin-provisioned storage, monitor the physical thin pool as well as the guest filesystem.

## 2. Prepare the VM

Confirm basic VM health:

```bash
hostnamectl
lsblk
df -h /
ip route
systemctl is-active qemu-guest-agent
systemctl is-active fstrim.timer
```

The VM needs working DNS, Internet access for packages and images, and SSH access from your workstation.

## 3. Clone the repository

```bash
git clone https://github.com/Tuhinzman/floci-aws-homelab.git
cd floci-aws-homelab
```

Run the remaining repository commands from this directory.

## 4. Install Docker

```bash
sudo bash scripts/install-docker.sh
```

Verify:

```bash
docker --version
sudo docker compose version
sudo docker run --rm hello-world
```

The Docker socket provides root-equivalent control over the VM. Do not expose it over the network.

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

The two addresses serve different contexts:

- `FLOCI_HOST_IP` is used by the VM shell and workstation.
- `FLOCI_INTERNAL_HOSTNAME=floci` is used by Lambda containers inside the Compose network.

Start Floci:

```bash
sudo docker compose --env-file .env -f compose/compose.yaml pull
sudo docker compose --env-file .env -f compose/compose.yaml up -d
```

Check status and health:

```bash
sudo docker compose --env-file .env -f compose/compose.yaml ps

set -a
. ./.env
set +a
curl -fsS "http://${FLOCI_HOST_IP}:4566/_localstack/health"

sudo docker inspect floci \
  --format 'Status={{.State.Status}} Health={{.State.Health.Status}}'
```

## 6. Install and isolate AWS CLI

```bash
sudo bash scripts/install-aws-cli.sh
bash scripts/configure-floci-cli.sh
```

Run the profile script as your normal Linux user, not through `sudo bash`.

Verify:

```bash
aws-floci sts get-caller-identity
```

Expected emulator account:

```text
000000000000
```

The `floci` profile uses dummy credentials. Never place real AWS keys in it.

## 7. Run the imperative validation sequence

Run these tests in order because later tests reuse resources created earlier.

### 7.1 Core services

```bash
bash scripts/smoke-test-core-services.sh
```

Expected final line:

```text
FLOCI_CORE_AWS_SMOKE_TEST=PASS
```

### 7.2 Core-service persistence

```bash
bash scripts/validate-persistence.sh
```

Expected final line:

```text
FLOCI_PERSISTENCE_VALIDATION=PASS
```

### 7.3 Docker-backed Lambda

```bash
bash scripts/smoke-test-lambda.sh
```

This packages and invokes a Python 3.13 function, asserts the response, and verifies the runtime container and `floci_default` network.

Expected final line:

```text
FLOCI_LAMBDA_SMOKE_TEST=PASS
```

### 7.4 SQS to Lambda to DynamoDB

```bash
bash scripts/smoke-test-sqs-lambda-dynamodb.sh
```

Validated path:

```text
SQS message
→ enabled event-source mapping
→ Docker-backed Lambda execution
→ DynamoDB PutItem
→ exact item read-back
```

Expected final line:

```text
FLOCI_SQS_LAMBDA_DYNAMODB_TEST=PASS
```

### 7.5 Complete event-chain persistence

```bash
bash scripts/validate-event-driven-persistence.sh
```

This restarts Floci, verifies the same queue, table, function, and mapping, then sends a new message and asserts a new DynamoDB item.

Expected final line:

```text
FLOCI_EVENT_DRIVEN_PERSISTENCE_TEST=PASS
```

## 8. Terraform lifecycle

Terraform uses separate resource names so it does not adopt or modify the manually validated reference stack.

### 8.1 Install Terraform

```bash
sudo bash scripts/install-terraform.sh
terraform version
```

The validated version is Terraform `1.16.0`.

### 8.2 Initial plan, apply, and validation

On a clean Terraform state, run:

```bash
bash scripts/terraform-apply-validate.sh
```

The script:

1. creates local ignored tfvars from `.env`
2. runs format, init, and validate
3. creates a saved plan
4. asserts the exact six-resource create set
5. applies the saved plan
6. validates Terraform state
7. runs a no-change plan
8. sends an SQS message
9. asserts the resulting DynamoDB item
10. verifies the Docker-backed Lambda runtime

Expected create plan:

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

### 8.3 Resume after a post-apply validation interruption

Do not rerun the initial six-create workflow when the saved plan already applied successfully.

Use:

```bash
bash scripts/terraform-resume-validate.sh
```

The reference lab has passed this path. It verified:

```text
TERRAFORM_MANAGED_STATE_EXACT_MATCH=PASS
TERRAFORM_DATA_STATE_EXACT_MATCH=PASS
TERRAFORM_CONVERGENCE=PASS
TERRAFORM_EVENT_DRIVEN_FUNCTIONAL_TEST=PASS
FLOCI_TERRAFORM_RESUME_VALIDATION=PASS
```

The expected data resources are:

```text
data.archive_file.lambda
data.aws_iam_policy_document.lambda_assume_role
data.aws_iam_policy_document.lambda_permissions
```

A data resource appearing in `terraform state list` is not an extra managed infrastructure resource.

### 8.4 Destroy and cleanup verification

The Terraform-managed resources remain present after successful apply and resume validation.

Destroy is a separate, guarded lifecycle step:

```bash
bash scripts/terraform-destroy-verify.sh
```

Run it only after reviewing the current state and explicitly deciding to remove the Terraform-managed stack.

The destroy script is designed to verify:

```text
exact six-resource destroy plan
→ apply saved destroy plan
→ managed Terraform state empty
→ SQS absent
→ DynamoDB absent
→ Lambda absent
→ IAM role absent
→ event-source mapping absent
→ Terraform Lambda runtime container absent
```

Do not use manual deletion, `terraform state rm`, or Floci volume removal as substitutes for the guarded destroy workflow.

## 9. Normal operations

Check status:

```bash
sudo docker compose --env-file .env -f compose/compose.yaml ps
```

View logs:

```bash
sudo docker compose --env-file .env -f compose/compose.yaml logs --tail=100 floci
```

List Floci and spawned containers:

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

Do not run `docker compose down -v` unless you intentionally want to delete the persistent Floci volume and its data.

## 10. Storage checks

```bash
df -h /
sudo docker system df
sudo docker volume ls
```

Lambda images remain in Docker's image cache. Do not run broad pruning commands without checking what other workloads use them.

On the Proxmox host, monitor the LVM-thin data percentage and maintain physical headroom.

## 11. Network stability

Keep the VM address stable with a DHCP reservation where possible.

```text
VM shell or workstation → http://<FLOCI_HOST_IP>:4566
Lambda container        → http://floci:4566
```

When the VM address changes:

1. update `.env`
2. re-run `scripts/configure-floci-cli.sh`
3. reconcile the Compose deployment
4. repeat the relevant validations

## 12. Cleanup boundaries

Imperative validation resources intentionally remain present for persistence and reboot tests.

Terraform-managed resources must be removed through the Terraform destroy workflow, not through manual API deletion.

Do not remove the Floci Docker volume when you intend to preserve lab state.

## 13. Troubleshooting notes

Common issues already encountered include:

- SSH host-key warnings after IP reuse
- AWS CLI installation failing because `unzip` was missing
- `sudo bash` using root's home and losing the normal user's profile
- a health check targeting `127.0.0.1` while the port was bound to the VM address
- SQS URLs changing to `http://floci:4566` after the internal hostname was enabled
- Terraform state validation accidentally counting data resources as managed resources
- Proxmox thin-pool over-provisioning warnings

See [troubleshooting.md](troubleshooting.md) for details.

## 14. Security and validation boundary

Keep these rules:

- use dummy credentials only
- do not expose TCP `4566` publicly
- do not expose the Docker socket over the network
- keep `.env`, tfvars, state, plans, and raw evidence out of Git
- sanitize private addresses, SSH data, machine IDs, container IDs, mapping UUIDs, message IDs, and generated test identifiers

The current verified boundary includes:

- core AWS-style service workflows
- core persistence across a Floci restart
- synchronous Docker-backed Lambda
- SQS to Lambda to DynamoDB integration
- event-chain processing after a Floci restart
- Terraform exact create plan
- Terraform saved-plan apply
- exact managed/data state validation
- no-change convergence
- Terraform-managed functional event processing

It does not yet include:

- Terraform destroy and remote absence proof
- persistence across a full Ubuntu VM or Proxmox host reboot
- real AWS IAM enforcement
- retry and dead-letter queue parity
- exactly-once processing
- production scaling, availability, quotas, or full AWS API parity

## 15. Next milestone

The Terraform-managed stack is validated and still present. The next lifecycle step is guarded Terraform destroy, but it must not run until the owner explicitly authorizes removal.

After destroy and absence proof, the remaining major validation is a full Ubuntu VM reboot followed by a new message through the manually validated event chain.
