# Floci AWS Homelab Runbook

This runbook is for building, operating, and checking a small local AWS learning environment with Floci. It is written for someone who wants to practice Cloud DevOps or Platform Engineering workflows without leaving billable AWS resources running while they learn.

The commands are intentionally simple. The goal is to make the lab easy to rebuild and easy to troubleshoot, not to hide the moving parts behind a large automation framework.

## 1. Before you start

You need:

- a Linux VM, preferably Ubuntu 24.04 LTS
- enough CPU, RAM, and disk for the services you plan to emulate
- a stable private IP for the VM
- Internet access for package and image downloads
- Git

A practical starting VM size is 6 vCPU, 16 GiB RAM, and an 80 GiB disk. You can use less for basic S3, SQS, DynamoDB, SSM, and Secrets Manager practice.

If the VM is hosted on thin-provisioned storage, check the physical storage pool before assigning a large virtual disk. A large logical disk does not mean that space is reserved physically, and an overcommitted thin pool can still fill up later.

## 2. Prepare the VM

Create an Ubuntu VM in your hypervisor and make sure it can:

- resolve DNS
- reach the Internet
- accept SSH connections from your workstation
- run the QEMU guest agent if you use Proxmox

After resizing the virtual disk, verify that the guest filesystem expanded too:

```bash
lsblk
findmnt /
df -h /
```

If the hypervisor supports discard/TRIM, enable it on the virtual disk and confirm the guest timer is active:

```bash
systemctl is-active fstrim.timer
systemctl is-enabled fstrim.timer
```

## 3. Clone the repository

```bash
git clone https://github.com/Tuhinzman/floci-aws-homelab.git
cd floci-aws-homelab
```

Run the remaining repository commands from this directory unless a section says otherwise.

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

The Docker socket gives root-equivalent control over this VM. Do not expose it over the network, and do not assume membership in the `docker` group is harmless.

## 5. Configure Floci

Copy the example environment file:

```bash
cp .env.example .env
```

Edit `.env` and set the private IP of the Floci VM:

```text
FLOCI_HOST_IP=192.168.1.50
FLOCI_VERSION=1.7.0
FLOCI_REGION=us-east-1
```

The `.env` file is ignored by Git because addresses and local settings vary between labs.

Start Floci:

```bash
sudo docker compose --env-file .env -f compose/compose.yaml pull
sudo docker compose --env-file .env -f compose/compose.yaml up -d
```

Check container state:

```bash
sudo docker compose --env-file .env -f compose/compose.yaml ps
```

Load the environment and check health:

```bash
set -a
. ./.env
set +a
curl -fsS "http://${FLOCI_HOST_IP}:4566/_localstack/health"
```

You should also see Docker report the container as healthy:

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

The installer needs `unzip`. The repository script installs it before running the official AWS CLI installer.

## 7. Configure an isolated Floci AWS profile

Run this as your normal Linux user, not inside `sudo bash`:

```bash
bash scripts/configure-floci-cli.sh
```

The script reads the repository `.env`, preserves existing AWS profiles, adds a dedicated `floci` profile with dummy credentials, and installs the `aws-floci` helper command.

Verify:

```bash
aws-floci sts get-caller-identity
```

The default Floci account should be:

```text
000000000000
```

Use `aws-floci` for local lab commands instead of typing the endpoint manually every time.

## 8. Validate the core services

```bash
bash scripts/smoke-test-core-services.sh
```

The test exercises:

- STS
- S3
- SQS
- DynamoDB
- SSM Parameter Store
- Secrets Manager

A successful run ends with:

```text
FLOCI_CORE_AWS_SMOKE_TEST=PASS
```

These resources are deliberately left in place so the persistence test can verify them after a restart.

## 9. Validate persistence

Run the persistence test from any directory. It resolves the repository path from the script location and reads the same `.env` and Compose file used during deployment.

```bash
bash scripts/validate-persistence.sh
```

The script restarts Floci, waits for the container to become healthy, and checks the previously created S3 object, SQS queue, DynamoDB item, SSM parameter, and secret.

A successful run ends with:

```text
S3_PERSISTENCE=PASS
SQS_PERSISTENCE=PASS
DYNAMODB_PERSISTENCE=PASS
SSM_PERSISTENCE=PASS
SECRETS_MANAGER_PERSISTENCE=PASS
FLOCI_PERSISTENCE_VALIDATION=PASS
```

## 10. Normal operations

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

### View logs

```bash
sudo docker compose --env-file .env -f compose/compose.yaml logs --tail=100 floci
```

### Restart Floci

```bash
sudo docker compose --env-file .env -f compose/compose.yaml restart floci
```

### Stop the lab

```bash
sudo docker compose --env-file .env -f compose/compose.yaml stop
```

### Start it again

```bash
sudo docker compose --env-file .env -f compose/compose.yaml start
```

Do not use `docker compose down -v` unless you intentionally want to remove the persistent volume and its data.

## 11. Storage checks

Floci itself is small, but container-backed services can consume disk quickly.

Inside the VM:

```bash
df -h /
sudo docker system df
sudo docker volume ls
```

On a Proxmox host using LVM-thin, also watch the thin-pool data percentage. Logical VM disk sizes can exceed the physical pool because of thin provisioning, but the pool must never be allowed to fill physically.

## 12. Network stability

The Floci address is included in returned service URLs, such as SQS queue URLs. That means the VM address should stay stable.

For a home lab, reserve the VM address in your router or DHCP server rather than guessing an unused static IP in the guest.

If the address changes:

1. update `.env`
2. re-run `scripts/configure-floci-cli.sh`
3. recreate the Floci container with `docker compose up -d`
4. repeat the smoke and persistence tests

## 13. Adding more AWS services

Floci exposes many AWS-compatible service APIs, but do not assume a service is fully validated because it appears as `running` in the health response.

Add services one workflow at a time:

```text
create resource
→ use the resource
→ read the result back
→ restart Floci if persistence matters
→ verify again
→ document only what was proven
```

Container-backed services such as Lambda, databases, Kubernetes, Kafka, or OpenSearch may create additional Docker containers and need more ports, memory, and storage than the core services tested here.

## 14. Security notes

This is a learning lab, not a public cloud endpoint.

Keep these rules:

- use dummy credentials only
- do not store real AWS keys in the Floci profile
- do not expose TCP 4566 to the public Internet
- do not expose `/var/run/docker.sock` over the network
- keep `.env` out of Git
- sanitize private IPs, MAC addresses, SSH keys, machine IDs, and real secrets before publishing evidence

## 15. Validation boundary

This runbook proves the workflows documented in this repository. It does not prove exact parity with AWS for IAM enforcement, VPC networking, managed EKS, availability, scaling, quotas, Multi-AZ behavior, pricing, or unsupported API operations.

Use Floci to learn cheaply and iterate quickly. Use real AWS when the behavior you need to prove depends on AWS itself.
