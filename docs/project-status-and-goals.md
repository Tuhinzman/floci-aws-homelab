# Project Status and Goals

Last updated: 2026-08-31 UTC / 2026-08-30 EDT

## What this project is

This project is a local AWS learning lab built with Proxmox, Ubuntu, Docker, Floci, AWS CLI, Python Lambda, SQS, DynamoDB, and Terraform.

The idea is simple: give learners a place to practice useful AWS-style workflows without creating a real cloud bill every time they want to experiment.

Floci is not treated as a replacement for AWS. It is a local practice and integration-testing environment. Anything that depends on real AWS networking, IAM enforcement, scaling, availability, quotas, or managed-service behavior still needs to be tested in AWS.

## Current status

```text
Platform foundation                         COMPLETE
Core AWS-style service validation           COMPLETE
Core-service persistence after Floci restart COMPLETE
Docker-backed Lambda validation             COMPLETE
SQS to Lambda to DynamoDB integration       COMPLETE
Event-chain persistence after Floci restart COMPLETE
Terraform static validation                 COMPLETE
Terraform exact create plan                 COMPLETE
Terraform saved-plan apply                  COMPLETE
Terraform managed/data state validation     COMPLETE
Terraform no-change convergence             COMPLETE
Terraform functional event validation       COMPLETE
Terraform exact destroy plan                COMPLETE
Terraform destroy                           COMPLETE
Terraform API absence checks                COMPLETE
Manual reference stack preserved            COMPLETE
Full Ubuntu VM reboot validation             COMPLETE
First portfolio release                     PENDING FINAL REVIEW
```

The main technical validation work is now complete. The remaining work is release preparation: review the public repository, confirm no private lab data is exposed, confirm CI is green, freeze the claim boundary, and create the first versioned release.

## Validated lab environment

```text
Hypervisor:       Proxmox VE / KVM
Guest OS:         Ubuntu 24.04 LTS
VM size:          6 vCPU, 16 GiB RAM, 80 GiB disk
Container engine: Docker Engine and Docker Compose
AWS emulator:     Floci 1.7.0
AWS client:       AWS CLI v2
IaC tool:         Terraform 1.16.0
AWS provider:     6.61.0
Archive provider: 2.8.0
Lambda runtime:   Python 3.13
```

Floci uses hybrid persistent storage. Its data is kept in a Docker volume, and the Docker socket allows Floci to start container-backed services such as Lambda runtimes.

## What has been proven

### Core AWS-style services

The following workflows were created and read back successfully:

| Service | Tested workflow |
| --- | --- |
| STS | identity and account read-back |
| S3 | create bucket, upload, list, read object |
| SQS | create queue, send, receive message |
| DynamoDB | create table, put item, get item |
| SSM Parameter Store | put and read parameter |
| Secrets Manager | create and read secret |

The tests check returned values instead of only trusting a successful command exit code.

### Docker-backed Lambda

A Python 3.13 Lambda function was packaged, created, and invoked through Floci.

The validation checked:

- function state `Active`
- invocation status `200`
- exact request and response data
- runtime image `public.ecr.aws/lambda/python:3.13`
- runtime attachment to `floci_default`

### Event-driven workflow

This complete path was tested:

```text
SQS message
→ Lambda event-source mapping
→ Docker-backed Lambda execution
→ DynamoDB PutItem
→ exact item read-back
```

The test checked the queue, function state, mapping state, SQS message ID, and the expected DynamoDB fields.

### Persistence after a Floci restart

The core resources remained readable after restarting Floci.

The manual event-driven queue, table, Lambda function, and event-source mapping also survived the restart. The same mapping stayed enabled, and a new SQS message still triggered Lambda and produced a new DynamoDB item.

### Terraform lifecycle

Terraform used a separate resource namespace so it never managed the manual reference stack.

The Terraform create plan was exactly:

```text
6 to add
0 to change
0 to destroy
```

The saved plan applied successfully. Terraform state was checked with managed resources and data resources separated correctly.

A later plan returned:

```text
No changes. Your infrastructure matches the configuration.
```

The Terraform-managed SQS → Lambda → DynamoDB path was then tested with a new message and an exact DynamoDB read-back.

The destroy plan was exactly:

```text
0 to add
0 to change
6 to destroy
```

After applying the saved destroy plan:

```text
Terraform managed state empty       PASS
SQS queue absent                    PASS
DynamoDB table absent               PASS
Lambda function absent              PASS
IAM role absent                     PASS
Event-source mapping absent         PASS
Terraform Lambda container absent   PASS
Floci still healthy                 PASS
Manual reference stack untouched    PASS
```

This closes the Terraform lifecycle from exact create plan through functional validation, convergence, destroy, and API absence proof.

### Full Ubuntu VM reboot

A normal Ubuntu VM reboot was also tested.

Before the reboot, Docker, Floci, the manual SQS queue, DynamoDB table, Lambda function, and event-source mapping were checked and used as the baseline.

After reboot:

```text
Docker auto-start                    PASS
Floci auto-start                     PASS
Floci health                         PASS
Same SQS queue                       PASS
Same DynamoDB table                  PASS
Same Lambda function                 PASS
Same event-source mapping            PASS
Mapping remained enabled             PASS
New SQS message                      PASS
New DynamoDB item                    PASS
Exact item assertions                PASS
Docker-backed Lambda runtime         PASS
Expected Docker network              PASS
```

The first post-reboot functional check hit a validation-parser error after the message had already been sent. The infrastructure was not rebuilt and the VM was not rebooted again. The test resumed in the same rebooted session using direct AWS CLI field queries, and the complete workflow passed.

This proves that the tested lab can recover from a normal guest-OS reboot and process a new event without recreating the application resources.

## Validation records

```text
docs/validation/v0.1-baseline.md
docs/validation/v0.2-lambda.md
docs/validation/v0.3-sqs-lambda-dynamodb.md
docs/validation/v0.4-event-driven-persistence.md
docs/validation/v0.5-terraform-apply-and-convergence.md
docs/validation/v0.6-terraform-destroy-and-cleanup.md
docs/validation/v0.7-full-vm-reboot.md
```

## Main goal

Build a reproducible, production-inspired local AWS learning platform where a learner can practice the full engineering lifecycle:

```text
prepare the VM
→ start the local AWS emulator
→ isolate credentials and endpoints
→ create services
→ connect services into a workflow
→ verify real results
→ test persistence and recovery
→ manage the same pattern with Terraform
→ prove convergence
→ destroy safely
→ prove resources are gone
→ recover after a VM reboot
→ document what was actually tested
```

## Why this matters for a learner

The useful skill is not memorizing individual AWS CLI commands. It is learning how services connect and how to prove that a system really works.

For example:

```text
message arrives
→ Lambda is triggered
→ application code runs
→ data is written
→ result is read back
```

That same way of thinking transfers directly to Cloud DevOps and Platform Engineering work.

## Project principles

1. Keep the design understandable before making it more advanced.
2. Define what success looks like before running a change.
3. Do not call a service validated just because it appears in a health list.
4. Prefer exact read-back checks over assumptions.
5. Keep manual reference resources separate from Terraform-managed resources.
6. Do not publish private addresses, credentials, Terraform state, tfvars, saved plans, or raw evidence.
7. Record failures and fixes, not only successful commands.
8. Finish the current lifecycle before adding more services.
9. Use real AWS when the claim depends on real AWS behavior.

## What this project does not prove

The current validation does not prove:

- recovery after a full Proxmox host reboot
- recovery after abrupt power loss
- exact AWS IAM authorization enforcement
- real VPC, subnet, route, NAT, or security-group behavior
- Multi-AZ availability
- AWS quotas
- production scaling or performance
- exactly-once SQS processing
- complete retry or dead-letter queue parity
- managed EKS parity
- full compatibility with every AWS API operation

## Remaining release work

The main technical gate is closed. Before creating the first stable portfolio release:

1. review the public repository for private or machine-specific data
2. review the README and runbook from a new learner's point of view
3. confirm all GitHub Actions checks are green
4. confirm local-only evidence and configuration are still excluded from Git
5. freeze the exact verified and unverified claim boundary
6. create the first versioned release

## Current one-line status

```text
The local AWS lab is verified through core services, Docker-backed Lambda, event-driven processing, Floci restart persistence, a complete Terraform create-to-destroy lifecycle, and successful recovery and event processing after a full Ubuntu VM reboot; only final public-repository review and release preparation remain.
```
