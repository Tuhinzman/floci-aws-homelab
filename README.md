# Floci AWS Homelab

[![Repository validation](https://github.com/Tuhinzman/floci-aws-homelab/actions/workflows/validate.yml/badge.svg)](https://github.com/Tuhinzman/floci-aws-homelab/actions/workflows/validate.yml)

A hands-on local AWS learning lab for junior Cloud DevOps and Platform Engineers who want to practice AWS-style workflows without keeping billable AWS infrastructure running.

## Why this project exists

Learning AWS properly usually means creating resources, breaking things, rebuilding them, and repeating the process. That is useful, but it can also create real cloud costs while you are still learning.

This repository documents a working alternative for day-to-day practice: **Floci running in Docker on an Ubuntu VM hosted by Proxmox**.

The goal is simple: give learners a practical place to use the AWS CLI, create services, test integrations, troubleshoot failures, and build repeatable operational habits locally before moving important validation to real AWS.

This project is not trying to claim that Floci is a complete replacement for AWS. Some AWS behavior can only be proven in the real cloud. Instead, this lab is meant to reduce the cost of learning and experimentation while still giving you useful hands-on experience.

## What has been validated

The current lab has been built and tested with:

- Ubuntu 24.04 LTS on Proxmox/KVM
- Docker Engine and Docker Compose
- Floci 1.7.0
- AWS CLI v2 with an isolated `floci` profile
- persistent Floci state using hybrid storage
- Docker-backed Lambda execution using the Python 3.13 runtime image

The following AWS-style workflows have been verified end to end:

| Service | Validation performed |
| --- | --- |
| STS | `get-caller-identity` |
| S3 | create bucket, upload object, list, read object |
| SQS | create queue, send message, receive message |
| DynamoDB | create table, put item, get item |
| SSM Parameter Store | put and read parameter |
| Secrets Manager | create and read secret |
| IAM | create and read back a Lambda execution role |
| Lambda | package Python code, create function, invoke synchronously, assert the response, and verify the real Docker runtime container and network |

The S3, SQS, DynamoDB, SSM, and Secrets Manager resources were verified again after restarting the Floci container. The Lambda workflow was then validated through a real `public.ecr.aws/lambda/python:3.13` runtime container attached to the Floci Docker network.

Validation records:

- [v0.1 core-service baseline](docs/validation/v0.1-baseline.md)
- [v0.2 Docker-backed Lambda validation](docs/validation/v0.2-lambda.md)

> **Important:** A service appearing in Floci's health output does not mean every AWS feature of that service has been validated. This repository clearly separates what Floci exposes from what has actually been tested here.

## Architecture

```text
Bare-metal server
└── Proxmox VE
    └── Ubuntu VM
        ├── Docker Engine
        │   ├── Floci
        │   │   ├── core AWS-compatible APIs
        │   │   ├── persistent Floci volume
        │   │   └── Docker socket
        │   └── Lambda runtime container
        │       ├── public.ecr.aws/lambda/python:3.13
        │       └── floci_default network
        └── AWS CLI v2
            └── isolated `floci` profile + `aws-floci` wrapper
```

The AWS CLI uses dummy credentials and a dedicated wrapper so lab commands are sent to Floci instead of real AWS. Docker-backed services can reach Floci through the internal hostname configured in `.env`.

## Repository layout

```text
.
├── .github/
│   └── workflows/
│       └── validate.yml
├── compose/
│   └── compose.yaml
├── docs/
│   ├── architecture.md
│   ├── runbook.md
│   ├── troubleshooting.md
│   └── validation/
│       ├── v0.1-baseline.md
│       └── v0.2-lambda.md
├── scripts/
│   ├── configure-floci-cli.sh
│   ├── install-aws-cli.sh
│   ├── install-docker.sh
│   ├── smoke-test-core-services.sh
│   ├── smoke-test-lambda.sh
│   └── validate-persistence.sh
├── .env.example
├── .gitignore
└── README.md
```

## Quick start

### 1. Prepare an Ubuntu VM

A practical starting size for this learning lab is:

```text
6 vCPU
16 GiB RAM
80 GiB disk
Ubuntu 24.04 LTS
```

You can start smaller for lightweight services. Container-backed services such as Lambda, databases, Kubernetes, Kafka, or OpenSearch need additional memory and disk.

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

Copy the example environment file and set the private IP address of the VM:

```bash
cp .env.example .env
nano .env
```

Start Floci:

```bash
sudo docker compose --env-file .env -f compose/compose.yaml pull
sudo docker compose --env-file .env -f compose/compose.yaml up -d
```

Load the environment into the current shell and check health:

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

The script reads `.env`, preserves existing AWS profiles, adds the isolated `floci` profile, and installs the `aws-floci` helper.

Verify that the CLI is talking to the local emulator:

```bash
aws-floci sts get-caller-identity
```

The default Floci account should report:

```text
000000000000
```

### 7. Run the core service smoke test

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

The first run may pull the Python 3.13 Lambda runtime image. A successful test verifies the IAM role, function creation, synchronous invocation, response content, runtime container, and Docker network attachment.

## Safety model

This lab intentionally uses:

- dummy AWS credentials
- a dedicated AWS profile named `floci`
- an `aws-floci` wrapper that always supplies the local endpoint
- a configurable private VM address instead of a hard-coded public endpoint
- an internal Docker hostname for spawned service containers

Do not put real AWS access keys in this repository or in the Floci profile.

## What this lab is good for

Use it to practice:

- AWS CLI workflows
- infrastructure automation
- event-driven service patterns
- local application integration testing
- Docker-backed Lambda execution
- troubleshooting and repeatable validation
- learning before spending money on a real AWS environment

## What it does not prove

A passing Floci test does **not** automatically prove:

- exact AWS IAM enforcement
- real AWS networking behavior
- production scaling or availability
- AWS service quotas
- Multi-AZ behavior
- production-grade EKS behavior
- exact parity with every AWS API or feature
- Lambda concurrency, layers, VPC integration, or event-source behavior unless separately tested

Use real AWS for final validation when those behaviors matter.

## Documentation

Start with the [runbook](docs/runbook.md) for the complete operator workflow. The [architecture guide](docs/architecture.md) explains the host, container, storage, and network boundaries. The [troubleshooting guide](docs/troubleshooting.md) captures real issues encountered while building this lab and how they were resolved.

## Project philosophy

The repository is intentionally practical. The focus is not on collecting configuration files for their own sake. Every documented validation comes from a workflow that was actually executed against the lab.

If you are new to Cloud DevOps, Platform Engineering, or AWS and want somewhere inexpensive to experiment freely, break things, rebuild them, and learn from the process, this project is for you.
