# Floci AWS Homelab

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
- Persistent Floci state using hybrid storage

The following AWS-style workflows have been verified end to end:

| Service | Validation performed |
| --- | --- |
| STS | `get-caller-identity` |
| S3 | create bucket, upload object, list, read object |
| SQS | create queue, send message, receive message |
| DynamoDB | create table, put item, get item |
| SSM Parameter Store | put and read parameter |
| Secrets Manager | create and read secret |

The same resources were verified again after restarting the Floci container, proving persistence for the tested services.

> **Important:** A service appearing in Floci's health output does not mean every AWS feature of that service has been validated. This repository clearly separates what is supported by Floci from what has actually been tested here.

## Architecture

```text
Bare-metal server
└── Proxmox VE
    └── Ubuntu VM
        ├── Docker Engine
        │   └── Floci
        │       ├── S3
        │       ├── SQS
        │       ├── DynamoDB
        │       ├── SSM Parameter Store
        │       ├── Secrets Manager
        │       └── other Floci-supported services
        └── AWS CLI v2
            └── isolated `floci` profile
```

The AWS CLI is intentionally configured with dummy credentials and a dedicated wrapper so lab commands are sent to Floci instead of real AWS.

## Repository layout

```text
.
├── compose/
│   └── compose.yaml
├── docs/
│   ├── architecture.md
│   ├── runbook.md
│   └── troubleshooting.md
├── scripts/
│   ├── configure-floci-cli.sh
│   ├── install-aws-cli.sh
│   ├── install-docker.sh
│   ├── smoke-test-core-services.sh
│   └── validate-persistence.sh
├── .env.example
├── .gitignore
└── README.md
```

## Quick start

### 1. Prepare an Ubuntu VM

A practical starting size for a learning lab is:

```text
6 vCPU
16 GiB RAM
80 GiB disk
Ubuntu 24.04 LTS
```

You can start smaller if you only plan to use lightweight services. Container-backed services such as databases, Kubernetes, Kafka, or OpenSearch will need more resources.

### 2. Install Docker

```bash
sudo bash scripts/install-docker.sh
```

### 3. Configure Floci

Copy the example environment file and set the IP address of the VM:

```bash
cp .env.example .env
nano .env
```

Then start Floci:

```bash
sudo docker compose --env-file .env -f compose/compose.yaml pull
sudo docker compose --env-file .env -f compose/compose.yaml up -d
```

Check health:

```bash
curl -fsS "http://${FLOCI_HOST_IP}:4566/_localstack/health"
```

### 4. Install AWS CLI v2

```bash
sudo bash scripts/install-aws-cli.sh
```

### 5. Create the isolated Floci CLI profile

```bash
bash scripts/configure-floci-cli.sh
```

Then verify that the CLI is talking to the local emulator:

```bash
aws-floci sts get-caller-identity
```

The default Floci account should report:

```text
000000000000
```

### 6. Run the core service smoke test

```bash
bash scripts/smoke-test-core-services.sh
```

### 7. Validate persistence

```bash
bash scripts/validate-persistence.sh
```

## Safety model

This lab intentionally uses:

- dummy AWS credentials
- a dedicated AWS profile named `floci`
- an `aws-floci` wrapper that always supplies the local endpoint
- a configurable private VM address instead of a hard-coded public endpoint

Do not put real AWS access keys in this repository or in the Floci profile.

## What this lab is good for

Use it to practice:

- AWS CLI workflows
- infrastructure automation
- event-driven service patterns
- local application integration testing
- Docker-based cloud service emulation
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

Use real AWS for final validation when those behaviors matter.

## Documentation

Start with the [runbook](docs/runbook.md) for the complete operator workflow. The [troubleshooting guide](docs/troubleshooting.md) captures real issues encountered while building this lab and how they were resolved.

## Project philosophy

The repository is intentionally practical. The focus is not on collecting configuration files for their own sake. Every documented validation comes from a workflow that was actually executed against the lab.

If you are new to Cloud DevOps, Platform Engineering, or AWS and want somewhere inexpensive to experiment freely, break things, rebuild them, and learn from the process, this project is for you.
