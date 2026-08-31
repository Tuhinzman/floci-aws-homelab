# Floci AWS Homelab

[![Repository validation](https://github.com/Tuhinzman/floci-aws-homelab/actions/workflows/validate.yml/badge.svg)](https://github.com/Tuhinzman/floci-aws-homelab/actions/workflows/validate.yml)

A hands-on local AWS learning lab for junior Cloud DevOps and Platform Engineers who want to practice AWS-style workflows without keeping billable AWS infrastructure running.

## Why this project exists

Learning AWS properly usually means creating resources, breaking things, rebuilding them, and repeating the process. That is useful, but it can also create real cloud costs while you are still learning.

This repository documents a working alternative for day-to-day practice: **Floci running in Docker on an Ubuntu VM hosted by Proxmox**.

The goal is to give learners a practical place to use AWS CLI, create and connect services, run Docker-backed Lambda functions, test event-driven systems, manage infrastructure with Terraform, troubleshoot failures, and build repeatable operational habits locally before final validation in real AWS.

This project does not claim that Floci is a complete replacement for AWS. Some behavior can only be proven in the real cloud. Instead, this lab reduces the cost of learning and experimentation while still providing meaningful hands-on experience.

## What has been validated

The current lab has been built and tested with:

- Ubuntu 24.04 LTS on Proxmox/KVM
- Docker Engine and Docker Compose
- Floci 1.7.0
- AWS CLI v2 with an isolated `floci` profile
- Terraform 1.16.0
- AWS provider 6.61.0
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
| Event-chain persistence | restart Floci, read back the same queue, table, function, and mapping, then process a new message successfully |
| Terraform event stack | exact six-resource create plan, saved-plan apply, managed/data state validation, no-change convergence, SQS → Lambda → DynamoDB functional assertion |

The core resources and complete event-driven chain were verified after restarting Floci. The event-source mapping retained the same UUID and remained enabled, and a new SQS message produced a new asserted DynamoDB item after restart.

Terraform also provisioned a separate event-driven stack. The live post-apply validation confirmed the exact managed and data state sets, a `No changes` convergence plan, an active Lambda function, an enabled mapping, Docker-backed processing, and an exact DynamoDB read-back. The Terraform-managed resources remain present until the guarded destroy step is explicitly authorized.

Validation records:

- [v0.1 core-service and persistence baseline](docs/validation/v0.1-baseline.md)
- [v0.2 Docker-backed Lambda validation](docs/validation/v0.2-lambda.md)
- [v0.3 SQS to Lambda to DynamoDB validation](docs/validation/v0.3-sqs-lambda-dynamodb.md)
- [v0.4 event-driven restart persistence validation](docs/validation/v0.4-event-driven-persistence.md)
- [v0.5 Terraform apply, convergence, and functional validation](docs/validation/v0.5-terraform-apply-and-convergence.md)

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
        │   │   └── persistent Lambda event-source mappings
        │   └── Docker-backed Lambda runtime containers
        │       └── Python 3.13 on floci_default
        ├── AWS CLI v2
        │   └── isolated floci profile + aws-floci wrapper
        └── Terraform 1.16.0
            └── separate IaC-managed event-driven stack
```

The validated event path is:

```text
SQS message
→ event-source mapping
→ Lambda runtime container
→ DynamoDB PutItem
→ exact item read-back
```

The same path was executed through both imperative validation scripts and Terraform-managed resources.

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
│       └── v0.5-terraform-apply-and-convergence.md
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

A clean environment can begin with:

```bash
bash scripts/terraform-apply-validate.sh
```

When a saved plan has already applied but validation stopped after apply, use the resume path instead of rerunning the initial create workflow:

```bash
bash scripts/terraform-resume-validate.sh
```

The reference lab has passed the resume path through no-change convergence and functional event processing.

The destroy workflow is intentionally separate:

```bash
bash scripts/terraform-destroy-verify.sh
```

Run destroy only after reviewing the live state and explicitly deciding to remove the Terraform-managed stack.

## Safety model

This lab intentionally uses:

- dummy AWS credentials
- a dedicated AWS profile named `floci`
- an `aws-floci` wrapper that always supplies the local endpoint
- a configurable private VM address
- an internal Docker hostname for Lambda-to-Floci communication
- a `.env` file excluded from Git
- separate names for manual and Terraform-managed resources
- local Terraform state and raw evidence excluded from the public repository

Do not put real AWS access keys in this repository or in the Floci profile.

## What this lab is good for

Use it to practice:

- AWS CLI workflows
- event-driven architecture
- Infrastructure as Code
- saved-plan apply and convergence validation
- local application integration testing
- Docker-backed Lambda execution
- service and integration persistence testing
- troubleshooting and observable validation
- learning before spending money on a real AWS environment

## What it does not prove

A passing Floci test does **not** automatically prove:

- persistence across a full VM or Proxmox host reboot
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

Start with the [project status and goals](docs/project-status-and-goals.md), then use the [runbook](docs/runbook.md) for the operator workflow. The [architecture document](docs/architecture.md) explains the VM, Docker, endpoint, persistence, Lambda networking, and Terraform model. The [troubleshooting guide](docs/troubleshooting.md) captures real issues encountered while building the lab.

## Project philosophy

The repository is intentionally practical. The focus is not on collecting configuration files for their own sake. Every verified claim comes from an executed workflow with an observable result and a read-back assertion.

If you are new to Cloud DevOps, Platform Engineering, or AWS and want somewhere inexpensive to experiment freely, break things, rebuild them, and learn from the process, this project is for you.
