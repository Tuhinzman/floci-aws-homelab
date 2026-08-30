# Floci AWS Homelab Runbook

This runbook explains how to build, operate, and validate a small local AWS learning environment with Floci. It is written for learners who want practical Cloud DevOps or Platform Engineering experience without leaving billable AWS resources running while they experiment.

The commands are intentionally direct. The goal is to make the lab easy to understand, rebuild, and troubleshoot rather than hiding it behind a large automation framework.

## 1. Before you start

You need:

- an Ubuntu 24.04 LTS virtual machine
- a stable private IP address for the VM
- Internet access for package and image downloads
- Git
- enough CPU, memory, and disk for the services you plan to run

The validated lab started with:

```text
6 vCPU
16 GiB RAM
80 GiB disk
```

This is a practical starting point, not a minimum requirement. Docker-backed Lambda execution also needs room for the runtime image and the spawned function containers.

When the VM uses thin-provisioned storage, check the physical storage pool as well as the logical VM disk size. An overcommitted thin pool can still fill even when individual guest filesystems look healthy.

## 2. Prepare the VM

Confirm that the VM can:

- resolve DNS
- reach the Internet
- accept SSH connections from your workstation
- run the QEMU guest agent when hosted on Proxmox

After resizing the virtual disk, verify that the guest partition and filesystem expanded:

```bash
lsblk
findmnt /
df -h /
```

When the hypervisor supports discard/TRIM, enable it on the virtual disk and confirm the guest timer:

```bash
systemctl is-active fstrim.timer
systemctl is-enabled fstrim.timer
```

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

Verify:

```bash
docker --version
sudo docker compose version
sudo docker run --rm hello-world
```

The Docker socket provides root-equivalent control over the VM. Do not expose it over the network, and do not assume that membership in the `docker` group is harmless.

## 5. Configure Floci

Copy the example environment file:

```bash
cp .env.example .env
```

Edit `.env`:

```text
FLOCI_HOST_IP=192.168.1.50
FLOCI_INTERNAL_HOSTNAME=floci
FLOCI_VERSION=1.7.0
FLOCI_REGION=us-east-1
```

The settings serve two different network contexts:

- `FLOCI_HOST_IP` is used by the VM shell and your workstation.
- `FLOCI_INTERNAL_HOSTNAME=floci` is used by Lambda containers inside the Compose network.

Keep the internal hostname as `floci` unless you deliberately change the Compose service name.

The local `.env` file is ignored by Git.

Start Floci:

```bash
sudo docker compose --env-file .env -f compose/compose.yaml pull
sudo docker compose --env-file .env -f compose/compose.yaml up -d
```

Check container state:

```bash
sudo docker compose --env-file .env -f compose/compose.yaml ps
```

Load the environment and query health:

```bash
set -a
. ./.env
set +a
curl -fsS "http://${FLOCI_HOST_IP}:4566/_localstack/health"
```

Confirm Docker health too:

```bash
sudo docker inspect floci \
  --format 'Status={{.State.Status}} Health={{.State.Health.Status}}'
```

## 6. Install AWS CLI v2

```bash
sudo bash scripts/install-aws-cli.sh
```

Verify:

```bash
aws --version
command -v aws
```

The installer requires `unzip`. The repository script installs it before running the AWS CLI installer.

## 7. Configure an isolated Floci profile

Run this as your normal Linux user, not inside `sudo bash`:

```bash
bash scripts/configure-floci-cli.sh
```

The script:

- reads `.env`
- preserves existing AWS profiles
- creates a dedicated `floci` profile with dummy credentials
- installs the `aws-floci` helper command

Verify:

```bash
aws-floci sts get-caller-identity
```

The default emulator account should be:

```text
000000000000
```

Use `aws-floci` for local lab operations instead of manually typing the endpoint for every command.

## 8. Validate the core services

```bash
bash scripts/smoke-test-core-services.sh
```

The script validates:

- STS
- S3
- SQS
- DynamoDB
- SSM Parameter Store
- Secrets Manager

A successful run ends with:

```text
STS_TEST=PASS
S3_TEST=PASS
SQS_TEST=PASS
DYNAMODB_TEST=PASS
SSM_TEST=PASS
SECRETS_MANAGER_TEST=PASS
FLOCI_CORE_AWS_SMOKE_TEST=PASS
```

The test resources remain present so the persistence test can read them after a restart.

## 9. Validate core-service persistence

```bash
bash scripts/validate-persistence.sh
```

The script restarts Floci, waits for health, and reads the previously created S3 object, SQS queue, DynamoDB item, SSM parameter, and secret.

Expected ending:

```text
S3_PERSISTENCE=PASS
SQS_PERSISTENCE=PASS
DYNAMODB_PERSISTENCE=PASS
SSM_PERSISTENCE=PASS
SECRETS_MANAGER_PERSISTENCE=PASS
FLOCI_PERSISTENCE_VALIDATION=PASS
```

When the internal hostname is enabled, an SQS queue URL begins with:

```text
http://floci:4566
```

That is expected. Docker-spawned services need an address resolvable inside the Compose network.

## 10. Validate Docker-backed Lambda

```bash
bash scripts/smoke-test-lambda.sh
```

The script:

1. packages a small Python function
2. creates or reads back an execution-role reference
3. creates a Python 3.13 Lambda function
4. waits for the function to become active
5. invokes it synchronously
6. asserts status code `200`
7. asserts the exact response and input event
8. verifies the real Lambda runtime container
9. verifies attachment to `floci_default`
10. reads the function configuration back

The first run may pull:

```text
public.ecr.aws/lambda/python:3.13
```

Expected ending:

```text
FUNCTION_PACKAGE=PASS
IAM_ROLE_TEST=PASS
LAMBDA_CREATE_TEST=PASS
LAMBDA_RESPONSE_ASSERTION=PASS
LAMBDA_INVOKE_TEST=PASS
LAMBDA_DOCKER_CONTAINER_TEST=PASS
FLOCI_LAMBDA_SMOKE_TEST=PASS
```

The script leaves the function and role present for inspection.

## 11. Validate SQS to Lambda to DynamoDB

Run the event-driven integration test:

```bash
bash scripts/smoke-test-sqs-lambda-dynamodb.sh
```

The script creates and validates this path:

```text
SQS message
→ enabled event-source mapping
→ Docker-backed Lambda execution
→ DynamoDB PutItem
→ exact item read-back
```

It performs the following work:

1. verifies the local STS account
2. creates the `FlociOrders` DynamoDB table
3. creates the `floci-orders-events` SQS queue
4. creates the Lambda role reference and inline policy
5. packages the Python event processor
6. creates `floci-orders-processor`
7. creates an SQS event-source mapping with batch size `1`
8. waits for the mapping to become `Enabled`
9. sends a unique order message
10. waits for the resulting DynamoDB item
11. asserts `order_id`, `status`, `source`, `message_id`, and `processed_by`
12. verifies the Docker-backed runtime and network

Expected ending:

```text
SQS_MESSAGE_SEND_TEST=PASS
SQS_EVENT_SOURCE_MAPPING_TEST=PASS
LAMBDA_ASYNC_PROCESSING_TEST=PASS
DYNAMODB_SIDE_EFFECT_TEST=PASS
FLOCI_SQS_LAMBDA_DYNAMODB_TEST=PASS
```

The function, mapping, queue, table, role, and test item remain present for inspection and the next persistence test.

## 12. Validate the complete event path after a Floci restart

This test requires the resources created in the previous section.

```bash
bash scripts/validate-event-driven-persistence.sh
```

The script will:

1. read the queue, table, function, and mapping before restart
2. restart Floci
3. verify that the same resources and mapping still exist
4. verify that the mapping remains `Enabled`
5. send a new unique SQS message
6. wait for a new Lambda execution
7. assert the new DynamoDB item
8. verify the Lambda runtime container and network after restart

This script is included and CI-checked, but its result must not be treated as verified until it is executed successfully on the lab.

A successful run ends with:

```text
SQS_RESOURCE_PERSISTENCE=PASS
DYNAMODB_RESOURCE_PERSISTENCE=PASS
LAMBDA_FUNCTION_PERSISTENCE=PASS
EVENT_SOURCE_MAPPING_PERSISTENCE=PASS
EVENT_DRIVEN_PROCESSING_AFTER_RESTART=PASS
FLOCI_EVENT_DRIVEN_PERSISTENCE_TEST=PASS
```

## 13. Normal operations

Run these commands from the repository root.

### Check status

```bash
sudo docker compose --env-file .env -f compose/compose.yaml ps
```

### Check health

```bash
set -a
. ./.env
set +a
curl -fsS "http://${FLOCI_HOST_IP}:4566/_localstack/health"
```

### View Floci logs

```bash
sudo docker compose --env-file .env -f compose/compose.yaml logs --tail=100 floci
```

### List Floci and spawned containers

```bash
sudo docker ps \
  --format 'table {{.Names}}\t{{.Image}}\t{{.Status}}\t{{.Networks}}'
```

### Restart Floci

```bash
sudo docker compose --env-file .env -f compose/compose.yaml restart floci
```

### Stop the lab

```bash
sudo docker compose --env-file .env -f compose/compose.yaml stop
```

### Start the lab

```bash
sudo docker compose --env-file .env -f compose/compose.yaml start
```

Do not run `docker compose down -v` unless you intentionally want to remove the persistent volume and its data.

## 14. Storage checks

Floci itself is small, but Docker-backed services can consume disk quickly.

Inside the VM:

```bash
df -h /
sudo docker system df
sudo docker volume ls
```

Lambda runtime images stay in the Docker image cache. Do not run broad pruning commands without checking whether other lab workloads use those images.

On Proxmox with LVM-thin, also monitor the host thin-pool data percentage. Logical VM disk allocations can exceed the physical pool, but the pool must not be allowed to fill physically.

## 15. Network stability

The VM address should remain stable because the `aws-floci` wrapper uses it. A DHCP reservation is safer than guessing an unused static address inside the guest.

Remember the two address contexts:

```text
VM shell or workstation → http://<FLOCI_HOST_IP>:4566
Lambda container        → http://floci:4566
```

When the VM address changes:

1. update `.env`
2. re-run `scripts/configure-floci-cli.sh`
3. run `docker compose up -d`
4. repeat the relevant validation scripts

## 16. Cleanup

The validation scripts intentionally leave resources present. Remove them only when you no longer need the evidence or the next persistence test.

List mappings before deleting the event-driven function:

```bash
aws-floci lambda list-event-source-mappings \
  --function-name floci-orders-processor
```

Delete each mapping using its UUID, then remove the function:

```bash
aws-floci lambda delete-event-source-mapping --uuid <mapping-uuid>
aws-floci lambda delete-function --function-name floci-orders-processor
```

Other optional cleanup commands:

```bash
aws-floci sqs delete-queue \
  --queue-url http://floci:4566/000000000000/floci-orders-events

aws-floci dynamodb delete-table --table-name FlociOrders
aws-floci lambda delete-function --function-name floci-hello
```

Do not remove the Floci volume when you intend to keep persistent test data.

## 17. Adding more services

Do not treat a service as validated merely because it appears as `running` in the Floci health response.

Use this pattern:

```text
create resource
→ use the resource
→ read the result back
→ inspect the underlying container when applicable
→ restart Floci when persistence matters
→ verify again
→ document only what was proven
```

Good future milestones include:

- Infrastructure as Code with Terraform or OpenTofu
- S3 event to Lambda
- SNS to SQS fan-out
- API Gateway to Lambda
- retry and dead-letter queue behavior
- a local relational database workflow

## 18. Security and validation boundary

This is a learning lab, not a public cloud endpoint.

Keep these rules:

- use dummy credentials only
- do not store real AWS keys in the Floci profile
- do not expose TCP 4566 to the public Internet
- do not expose the Docker socket over the network
- keep `.env` out of Git
- sanitize private addresses, SSH data, machine identifiers, container IDs, mapping UUIDs, and test identifiers before publishing evidence

The current verified boundary covers the core services, their restart persistence, synchronous Docker-backed Lambda execution, and the SQS to Lambda to DynamoDB integration.

It does not prove real AWS IAM enforcement, VPC behavior, exactly-once processing, retry semantics, production scaling, availability, quotas, Multi-AZ behavior, or full AWS API parity.

Use Floci to learn cheaply and iterate quickly. Use real AWS when the behavior you need to prove depends on AWS itself.
