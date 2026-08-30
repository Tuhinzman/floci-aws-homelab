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
Python 3.13 Lambda runtime containers
```

This is a practical starting size, not a minimum. Heavier services such as databases, Kubernetes, Kafka, or OpenSearch may need more memory and disk.

When Proxmox uses thin-provisioned storage, monitor the physical thin pool as well as the guest filesystem. A large virtual disk does not reserve the same amount of physical space.

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

The VM needs working DNS, Internet access for packages and container images, and SSH access from your workstation.

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

The two addresses have different purposes:

- `FLOCI_HOST_IP` is used by the VM shell and your workstation.
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

Install AWS CLI v2:

```bash
sudo bash scripts/install-aws-cli.sh
```

Create the local profile as your normal Linux user, not through `sudo bash`:

```bash
bash scripts/configure-floci-cli.sh
```

Verify the endpoint and emulator account:

```bash
aws-floci sts get-caller-identity
```

Expected account:

```text
000000000000
```

The `floci` profile uses dummy credentials. Never place real AWS keys in this profile.

## 7. Run the validation sequence

Run the tests in this order because later tests reuse resources created earlier.

### 7.1 Core services

```bash
bash scripts/smoke-test-core-services.sh
```

This validates STS, S3, SQS, DynamoDB, SSM Parameter Store, and Secrets Manager.

Expected final line:

```text
FLOCI_CORE_AWS_SMOKE_TEST=PASS
```

### 7.2 Core-service persistence

```bash
bash scripts/validate-persistence.sh
```

This restarts Floci and reads the core resources again.

Expected final line:

```text
FLOCI_PERSISTENCE_VALIDATION=PASS
```

### 7.3 Docker-backed Lambda

```bash
bash scripts/smoke-test-lambda.sh
```

This packages and invokes a Python 3.13 function, asserts the response, and verifies the real Lambda runtime container and `floci_default` network attachment.

Expected final line:

```text
FLOCI_LAMBDA_SMOKE_TEST=PASS
```

### 7.4 SQS to Lambda to DynamoDB

```bash
bash scripts/smoke-test-sqs-lambda-dynamodb.sh
```

This validates:

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

Run this after the event-driven smoke test:

```bash
bash scripts/validate-event-driven-persistence.sh
```

This test has been executed successfully on the reference lab. It verified that the same queue, DynamoDB table, Lambda function, event-source mapping UUID, and enabled mapping state survived a Floci restart. It then sent a new message and asserted a new DynamoDB item produced by a new Docker-backed Lambda execution.

Expected final line:

```text
FLOCI_EVENT_DRIVEN_PERSISTENCE_TEST=PASS
```

The sanitized evidence is recorded in:

```text
docs/validation/v0.4-event-driven-persistence.md
```

## 8. Normal operations

Run these commands from the repository root.

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

## 9. Storage checks

Inside the VM:

```bash
df -h /
sudo docker system df
sudo docker volume ls
```

Lambda runtime images remain in Docker's local image cache. Do not run broad pruning commands without checking what other workloads use those images.

On the Proxmox host, monitor the LVM-thin data percentage and maintain physical headroom.

## 10. Network stability

Keep the VM address stable with a DHCP reservation where possible.

Remember the two address contexts:

```text
VM shell or workstation → http://<FLOCI_HOST_IP>:4566
Lambda container        → http://floci:4566
```

When the VM address changes:

1. update `.env`
2. re-run `scripts/configure-floci-cli.sh`
3. run `docker compose up -d` with the repository Compose file
4. repeat the relevant validation scripts

## 11. Cleanup

The validation scripts intentionally leave resources present so they can be inspected and used by persistence tests.

List event-source mappings before deleting the event function:

```bash
aws-floci lambda list-event-source-mappings \
  --function-name floci-orders-processor
```

Delete each mapping before deleting the function:

```bash
aws-floci lambda delete-event-source-mapping --uuid <mapping-uuid>
aws-floci lambda delete-function --function-name floci-orders-processor
```

Optional cleanup:

```bash
aws-floci sqs delete-queue \
  --queue-url http://floci:4566/000000000000/floci-orders-events

aws-floci dynamodb delete-table --table-name FlociOrders
aws-floci lambda delete-function --function-name floci-hello
```

Do not remove the Floci Docker volume when you intend to keep persistent lab state.

## 12. Troubleshooting notes

Common issues already encountered in the reference build include:

- SSH host-key warnings after an IP was reused
- AWS CLI installation failing because `unzip` was missing
- `sudo bash` using root's home and losing the normal user's `floci` profile
- a health check targeting `127.0.0.1` while port `4566` was bound only to the VM address
- SQS URLs changing to `http://floci:4566` after the internal Docker hostname was enabled
- thin-pool over-provisioning warnings on Proxmox

See [troubleshooting.md](troubleshooting.md) for the detailed fixes.

## 13. Security and validation boundary

Keep these rules:

- use dummy credentials only
- do not expose TCP `4566` to the public Internet
- do not expose `/var/run/docker.sock` over the network
- keep `.env` out of Git
- sanitize private addresses, SSH data, machine identifiers, container IDs, mapping UUIDs, and generated test identifiers before publishing evidence

The verified boundary includes core-service workflows, core persistence, synchronous Docker-backed Lambda, the SQS to Lambda to DynamoDB integration, and successful processing after a Floci container restart.

It does not prove:

- persistence across a full Ubuntu VM or Proxmox host reboot
- real AWS IAM enforcement
- retry and dead-letter queue behavior
- partial batch failure handling
- exactly-once processing
- production scaling, availability, quotas, or full AWS API parity

## 14. Next milestone

The next high-value step is to replace imperative resource creation with Infrastructure as Code:

```text
Terraform or OpenTofu
→ provision SQS, Lambda, event-source mapping, DynamoDB, and IAM references in Floci
→ send a test message
→ assert the DynamoDB result
→ destroy the IaC-managed resources
```

A separate full-VM reboot test can then extend the persistence boundary beyond the Floci container.
