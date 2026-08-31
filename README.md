# Floci AWS Homelab

[![Repository validation](https://github.com/Tuhinzman/floci-aws-homelab/actions/workflows/validate.yml/badge.svg)](https://github.com/Tuhinzman/floci-aws-homelab/actions/workflows/validate.yml)

A hands-on local AWS learning lab for junior Cloud DevOps and Platform Engineers who want to practice AWS-style workflows without keeping billable AWS infrastructure running.

## Why this project exists

Learning AWS properly usually means creating resources, breaking things, rebuilding them, and repeating the process. That is useful, but it can also create real cloud costs while you are still learning.

This repository documents a practical local environment built with **Proxmox, Ubuntu, Docker, Floci, AWS CLI, Lambda, SQS, DynamoDB, and Terraform**.

The goal is to give learners a place to practice connected AWS-style workflows, troubleshoot them, manage them with Infrastructure as Code, and prove the results before moving AWS-specific validation to the real cloud.

Floci is not treated as a complete replacement for AWS. It is a learning and integration-testing environment.

## What has been validated

The reference lab uses:

- Ubuntu 24.04 LTS on Proxmox/KVM
- Docker Engine and Docker Compose
- Floci 1.7.0
- AWS CLI v2 with an isolated `floci` profile
- Terraform 1.16.0
- AWS provider 6.61.0
- Archive provider 2.8.0
- Docker-backed Python 3.13 Lambda runtimes

Verified workflows:

| Service or workflow | Validation performed |
| --- | --- |
| STS | identity and account read-back |
| S3 | create bucket, upload, list, read object |
| SQS | create queue, send, receive message |
| DynamoDB | create table, put item, get item |
| SSM Parameter Store | put and read parameter |
| Secrets Manager | create and read secret |
| Lambda | package, create, invoke, assert response, inspect runtime container |
| SQS → Lambda → DynamoDB | create mapping, send message, run Lambda asynchronously, assert DynamoDB side effect |
| Event-chain persistence | restart Floci, read the same resources back, process another message |
| Terraform create lifecycle | exact six-resource plan, saved-plan apply, state validation, no-change convergence, functional event test |
| Terraform destroy lifecycle | exact six-resource destroy plan, saved-plan destroy, empty managed state, API absence proof, runtime cleanup |

The manual event-driven reference stack survived a Floci restart and remained untouched by the Terraform create/destroy lifecycle.

## Architecture

```text
Bare-metal server
└── Proxmox VE
    └── Ubuntu VM
        ├── Docker Engine
        │   ├── Floci
        │   │   ├── persistent service state
        │   │   ├── S3, SQS, DynamoDB, SSM, Secrets Manager
        │   │   └── Lambda event-source mappings
        │   └── Docker-backed Lambda runtime containers
        │       └── Python 3.13 on floci_default
        ├── AWS CLI v2
        │   └── isolated floci profile + aws-floci wrapper
        └── Terraform 1.16.0
            └── separate IaC-managed event-driven stack
```

The main event path is:

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
│   ├── project-status-and-goals.md
│   ├── runbook.md
│   ├── troubleshooting.md
│   └── validation/
│       ├── v0.1-baseline.md
│       ├── v0.2-lambda.md
│       ├── v0.3-sqs-lambda-dynamodb.md
│       ├── v0.4-event-driven-persistence.md
│       ├── v0.5-terraform-apply-and-convergence.md
│       └── v0.6-terraform-destroy-and-cleanup.md
├── scripts/
│   ├── configure-floci-cli.sh
│   ├── install-aws-cli.sh
│   ├── install-docker.sh
│   ├── install-terraform.sh
│   ├── smoke-test-core-services.sh
│   ├── smoke-test-lambda.sh
│   ├── smoke-test-sqs-lambda-dynamodb.sh
│   ├── terraform-apply-validate.sh
│   ├── terraform-destroy-verify.sh
│   ├── terraform-resume-validate.sh
│   ├── validate-event-driven-persistence.sh
│   └── validate-persistence.sh
├── terraform/
│   └── event-driven/
├── .env.example
├── .gitignore
└── README.md
```

## Quick start

### 1. Prepare an Ubuntu VM

A practical starting size is:

```text
6 vCPU
16 GiB RAM
80 GiB disk
Ubuntu 24.04 LTS
```

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

Example:

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

### 5. Install AWS CLI v2 and create the isolated profile

```bash
sudo bash scripts/install-aws-cli.sh
bash scripts/configure-floci-cli.sh
aws-floci sts get-caller-identity
```

The default emulator account should report:

```text
000000000000
```

### 6. Run the imperative validation sequence

```bash
bash scripts/smoke-test-core-services.sh
bash scripts/validate-persistence.sh
bash scripts/smoke-test-lambda.sh
bash scripts/smoke-test-sqs-lambda-dynamodb.sh
bash scripts/validate-event-driven-persistence.sh
```

### 7. Install Terraform

```bash
sudo bash scripts/install-terraform.sh
terraform version
```

### 8. Run the Terraform lifecycle

On a clean Terraform state:

```bash
bash scripts/terraform-apply-validate.sh
```

If apply already succeeded but the post-apply validation was interrupted, use:

```bash
bash scripts/terraform-resume-validate.sh
```

After the stack is fully validated and you intentionally want to remove it:

```bash
bash scripts/terraform-destroy-verify.sh
```

The reference lab has successfully completed all three paths, including API absence checks after destroy.

## Safety model

This lab uses:

- dummy AWS credentials
- a dedicated AWS profile named `floci`
- an `aws-floci` wrapper that always points to the local endpoint
- a configurable private VM address
- an internal Docker hostname for Lambda-to-Floci communication
- separate names for manual and Terraform-managed resources
- local Terraform state, tfvars, saved plans, and raw evidence excluded from Git

Do not put real AWS access keys in the Floci profile or public repository.

## What this lab is good for

Use it to practice:

- AWS CLI workflows
- event-driven architecture
- Infrastructure as Code
- saved-plan apply and destroy
- no-change convergence
- local application integration testing
- Docker-backed Lambda execution
- persistence and recovery checks
- troubleshooting and observable validation

## What it does not prove

This project does not automatically prove:

- persistence across a full VM or Proxmox host reboot
- exact AWS IAM enforcement
- real VPC and networking behavior
- retries, dead-letter queues, or every event-source option
- exactly-once message processing
- production scaling or availability
- AWS service quotas
- Multi-AZ behavior
- managed EKS parity
- full AWS API parity

Use real AWS when those behaviors matter.

## Documentation

Start with [Project Status and Goals](docs/project-status-and-goals.md), then use the [Runbook](docs/runbook.md) for the operator workflow. The [Architecture](docs/architecture.md) document explains the VM, Docker, endpoint, persistence, Lambda networking, and Terraform model. The [Troubleshooting](docs/troubleshooting.md) guide records issues encountered during the build.

## Current next step

The Terraform lifecycle is complete. The remaining major validation before the first portfolio release is a **full Ubuntu VM reboot** followed by a new message through the preserved manual SQS → Lambda → DynamoDB stack.
