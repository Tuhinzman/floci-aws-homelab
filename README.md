# Floci AWS Homelab

[![Repository validation](https://github.com/Tuhinzman/floci-aws-homelab/actions/workflows/validate.yml/badge.svg)](https://github.com/Tuhinzman/floci-aws-homelab/actions/workflows/validate.yml)

A hands-on local AWS learning lab for junior Cloud DevOps and Platform Engineers who want to practice AWS-style workflows without keeping billable AWS infrastructure running.

## Why this project exists

Learning AWS properly usually means creating resources, breaking things, rebuilding them, and repeating the process. That is useful, but it can also create real cloud costs while you are still learning.

This repository documents a working alternative for day-to-day practice: **Floci running in Docker on an Ubuntu VM hosted by Proxmox**.

The goal is simple: give learners a practical place to use the AWS CLI, create services, connect them, test integrations, troubleshoot failures, and build repeatable operational habits locally before moving important validation to real AWS.

This project does not claim that Floci is a complete replacement for AWS. Some behavior can only be proven in the real cloud. Instead, this lab reduces the cost of learning and experimentation while still providing meaningful hands-on experience.

## What has been validated

The current lab has been built and tested with:

- Ubuntu 24.04 LTS on Proxmox/KVM
- Docker Engine and Docker Compose
- Floci 1.7.0
- AWS CLI v2 with an isolated `floci` profile
- persistent Floci state using hybrid storage
- Docker-backed Python 3.13 Lambda runtimes

The following AWS-style workflows have been verified end to end:

| Service or workflow | Validation performed |
| --- | --- |
| STS | `get-caller-identity` |
| S3 | create bucket, upload object, list, read object |
| SQS | create queue, send message, receive message |
| DynamoDB | create table, put item, get item |
| SSM Parameter Store | put and read parameter |
| Secrets Manager | create and read secret |
| Lambda | package, create, invoke, assert response, inspect runtime container |
| SQS → Lambda → DynamoDB | create mapping, send message, execute Lambda asynchronously, assert DynamoDB side effect |

The core S3, SQS, DynamoDB, SSM, and Secrets Manager resources were verified again after restarting the Floci container.

Validation records:

- [v0.1 core-service and persistence baseline](docs/validation/v0.1-baseline.md)
- [v0.2 Docker-backed Lambda validation](docs/validation/v0.2-lambda.md)
- [v0.3 SQS to Lambda to DynamoDB validation](docs/validation/v0.3-sqs-lambda-dynamodb.md)

> **Important:** A service appearing in Floci's health output does not mean every AWS feature of that service has been validated. This repository separates what Floci reports as available from what was actually exercised and asserted here.

## Architecture

```text
Bare-metal server
└── Proxmox VE
    └── Ubuntu VM
        ├── Docker Engine
        │   ├── Floci
        │   │   ├── persistent service state
        │   │   ├── S3, SQS, DynamoDB, SSM, Secrets Manager
        │   │   └── Lambda event-source mapping
        │   └── Docker-backed Lambda runtime containers
        │       └── Python 3.13 on floci_default
        └── AWS CLI v2
            └── isolated floci profile + aws-floci wrapper
```

The validated event-driven path is:

```text
SQS message
→ event-source mapping
→ Lambda runtime container
→ DynamoDB PutItem
→ exact item read-back
```

## Repository layout

```text
.
├── .github/workflows/
│   └── validate.yml
├── compose/
│   └── compose.yaml
├── docs/
│   ├── architecture.md
│   ├── runbook.md
│   ├── troubleshooting.md
│   └── validation/
│       ├── v0.1-baseline.md
│       ├── v0.2-lambda.md
│       └── v0.3-sqs-lambda-dynamodb.md
├── scripts/
│   ├── configure-floci-cli.sh
│   ├── install-aws-cli.sh
│   ├── install-docker.sh
│   ├── smoke-test-core-services.sh
│   ├── smoke-test-lambda.sh
│   ├── smoke-test-sqs-lambda-dynamodb.sh
│   ├── validate-event-driven-persistence.sh
│   └── validate-persistence.sh
├── .env.example
├── .gitignore
└── README.md
```

## Quick start

### 1. Prepare an Ubuntu VM

A practical starting size for this lab is:

```text
6 vCPU
16 GiB RAM
80 GiB disk
Ubuntu 24.04 LTS
```

Lightweight services can run with less. Databases, Kubernetes, Kafka, OpenSearch, or several simultaneous Lambda runtimes may require more resources.

### 2. Clone the repository

```bash
git clone https://github.com/Tuhinzman/floci-aws-homelab.git
cd floci-aws-homelab
```

### 3. Install Docker

```bash
sudo bash scripts/install-docker.sh
```

### 4. Configure and start Floci

```bash
cp .env.example .env
nano .env
```

Set the private address of the VM. Keep the internal hostname as `floci` so Docker-spawned Lambda containers can resolve the emulator inside the Compose network.

```text
FLOCI_HOST_IP=192.168.1.50
FLOCI_INTERNAL_HOSTNAME=floci
FLOCI_VERSION=1.7.0
FLOCI_REGION=us-east-1
```

Start Floci:

```bash
sudo docker compose --env-file .env -f compose/compose.yaml pull
sudo docker compose --env-file .env -f compose/compose.yaml up -d
```

Check health:

```bash
set -a
. ./.env
set +a
curl -fsS "http://${FLOCI_HOST_IP}:4566/_localstack/health"
```

### 5. Install AWS CLI v2

```bash
sudo bash scripts/install-aws-cli.sh
```

### 6. Create the isolated Floci CLI profile

Run this as your normal Linux user, not with `sudo`:

```bash
bash scripts/configure-floci-cli.sh
```

Verify:

```bash
aws-floci sts get-caller-identity
```

The default emulator account should report:

```text
000000000000
```

### 7. Run the core-service smoke test

```bash
bash scripts/smoke-test-core-services.sh
```

### 8. Validate core-service persistence

```bash
bash scripts/validate-persistence.sh
```

### 9. Validate Docker-backed Lambda

```bash
bash scripts/smoke-test-lambda.sh
```

The first invocation may pull the official Python Lambda runtime image.

### 10. Validate the event-driven workflow

```bash
bash scripts/smoke-test-sqs-lambda-dynamodb.sh
```

This sends a unique SQS message, waits for Lambda to process it, and asserts the resulting DynamoDB item.

### 11. Test the event path after restarting Floci

Run this only after the event-driven smoke test has created its resources:

```bash
bash scripts/validate-event-driven-persistence.sh
```

The script is included and CI-checked. Its restart result remains outside the verified claim boundary until it passes on the lab.

## Safety model

This lab intentionally uses:

- dummy AWS credentials
- a dedicated AWS profile named `floci`
- an `aws-floci` wrapper that always supplies the local endpoint
- a configurable private VM address
- an internal Docker hostname for Lambda-to-Floci communication
- a `.env` file excluded from Git

Do not put real AWS access keys in this repository or in the Floci profile.

## What this lab is good for

Use it to practice:

- AWS CLI workflows
- event-driven architecture
- infrastructure automation
- local application integration testing
- Docker-backed Lambda execution
- service persistence testing
- troubleshooting and observable validation
- learning before spending money on a real AWS environment

## What it does not prove

A passing Floci test does **not** automatically prove:

- exact AWS IAM enforcement
- real VPC and networking behavior
- retries, dead-letter queues, or every event-source option
- exactly-once message processing
- production scaling or availability
- AWS service quotas
- Multi-AZ behavior
- production-grade EKS behavior
- exact parity with every AWS API or feature

Use real AWS for final validation when those behaviors matter.

## Documentation

Start with the [runbook](docs/runbook.md) for the complete operator workflow. The [architecture document](docs/architecture.md) explains the VM, Docker, endpoint, persistence, and Lambda networking model. The [troubleshooting guide](docs/troubleshooting.md) captures real issues encountered while building the lab.

## Project philosophy

The repository is intentionally practical. The focus is not on collecting configuration files for their own sake. Every verified claim comes from an executed workflow with an observable result and a read-back assertion.

If you are new to Cloud DevOps, Platform Engineering, or AWS and want somewhere inexpensive to experiment freely, break things, rebuild them, and learn from the process, this project is for you.
