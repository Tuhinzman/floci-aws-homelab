# Project Status and Goals

Last updated: 2026-08-31 UTC / 2026-08-30 EDT

## What this project is

This project is a local AWS learning lab built with Proxmox, Ubuntu, Docker, Floci, AWS CLI, Python Lambda, SQS, DynamoDB, and Terraform.

The main idea is simple: a learner should be able to practice useful AWS-style workflows without creating a real cloud bill every time they want to experiment.

Floci is not treated as a replacement for AWS. It is a local practice environment. When a behavior depends on real AWS networking, IAM enforcement, scaling, availability, quotas, or managed-service behavior, that still needs to be tested in AWS.

## Current status

```text
Platform foundation                         COMPLETE
Core AWS-style service validation           COMPLETE
Core-service restart persistence            COMPLETE
Docker-backed Lambda validation             COMPLETE
SQS to Lambda to DynamoDB integration       COMPLETE
Event-chain persistence after Floci restart COMPLETE
Repository documentation and CI             COMPLETE
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
Full Ubuntu VM reboot validation             NOT YET EXECUTED
First portfolio release                     NOT YET FROZEN
```

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

Floci uses hybrid persistent storage. Its data is stored in a Docker volume, and the Docker socket is mounted so Floci can start container-backed services such as Lambda runtimes.

## What has been proven so far

### Core services

The following workflows were created and read back successfully:

| Service | Tested workflow |
| --- | --- |
| STS | identity and account read-back |
| S3 | create bucket, upload, list, read object |
| SQS | create queue, send, receive message |
| DynamoDB | create table, put item, get item |
| SSM Parameter Store | put and read parameter |
| Secrets Manager | create and read secret |

These tests check returned values rather than only trusting a successful exit code.

### Persistence after a Floci restart

The same S3 object, SQS queue, DynamoDB item, SSM parameter, and secret were read back after restarting Floci.

### Docker-backed Lambda

A Python 3.13 Lambda function was packaged, created, and invoked through Floci.

The validation checked:

- function state `Active`
- invocation status `200`
- exact request and response data
- real runtime image `public.ecr.aws/lambda/python:3.13`
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

The test checked the queue ARN, function state, mapping state, SQS message ID, and the expected DynamoDB fields.

### Event chain after a Floci restart

The manually created queue, table, Lambda function, and event-source mapping were read back after a Floci restart. The mapping kept the same UUID and stayed enabled.

A new message sent after restart triggered Lambda and created a new DynamoDB item successfully.

## Terraform lifecycle

Terraform uses a separate resource namespace so it does not manage or delete the manual reference stack.

The Terraform-managed resources were:

```text
DynamoDB table:       FlociTerraformOrders
SQS queue:            floci-terraform-orders
IAM role:             floci-terraform-orders-role
IAM inline policy:    floci-terraform-orders-policy
Lambda function:      floci-terraform-orders-processor
Event-source mapping: SQS to Lambda
```

### Create path

The saved plan was exactly:

```text
6 to add
0 to change
0 to destroy
```

The saved plan applied successfully:

```text
6 added
0 changed
0 destroyed
```

Terraform state was then checked with managed resources and data resources separated correctly.

### No-change convergence

A second plan returned:

```text
No changes. Your infrastructure matches the configuration.
```

The Terraform-managed SQS → Lambda → DynamoDB workflow was then exercised with a new message and an exact DynamoDB read-back.

### Destroy and cleanup

The destroy plan was exactly:

```text
0 to add
0 to change
6 to destroy
```

The saved destroy plan completed successfully:

```text
0 added
0 changed
6 destroyed
```

Cleanup was checked in several ways:

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

This closes the Terraform lifecycle from exact create plan through functional validation and clean destroy.

Validation records:

```text
docs/validation/v0.1-baseline.md
docs/validation/v0.2-lambda.md
docs/validation/v0.3-sqs-lambda-dynamodb.md
docs/validation/v0.4-event-driven-persistence.md
docs/validation/v0.5-terraform-apply-and-convergence.md
docs/validation/v0.6-terraform-destroy-and-cleanup.md
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
→ test persistence
→ manage the same pattern with Terraform
→ prove convergence
→ destroy safely
→ prove resources are gone
→ document what was actually tested
```

## Why this matters for a learner

The value is not in memorizing individual AWS CLI commands. The useful skill is understanding how services connect and how to prove that a system is really working.

For example:

```text
message arrives
→ Lambda is triggered
→ application code runs
→ data is written
→ result is read back
```

The same thinking transfers to real Cloud DevOps and Platform Engineering work.

## Project principles

The project follows a few simple rules:

1. Keep the design understandable before making it more advanced.
2. Define what success looks like before running a change.
3. Do not call a service validated just because it appears in a health list.
4. Prefer exact read-back assertions over assumptions.
5. Keep manual evidence resources separate from Terraform-managed resources.
6. Do not publish private addresses, credentials, Terraform state, tfvars, saved plans, or raw evidence.
7. Record failures and fixes, not only successful commands.
8. Finish the current lifecycle before adding more services.
9. Use real AWS when the claim depends on real AWS behavior.

## Definition of done for the first portfolio release

Most of the technical lifecycle is now complete. The remaining release gate is:

```text
full Ubuntu VM reboot
→ Docker starts automatically
→ Floci becomes healthy
→ manual queue, table, function, and mapping are still present
→ send a new SQS message
→ Lambda runs
→ a new DynamoDB item is read back and asserted
```

After that:

- update the final validation record
- run a public repository privacy review
- confirm GitHub Actions is green
- freeze the documented claim boundary
- create the first versioned release

## What this project does not prove

This project does not prove:

- exact AWS IAM authorization enforcement
- real VPC, subnet, route, NAT, or security-group behavior
- Multi-AZ availability
- AWS quotas
- production scaling or performance
- exactly-once SQS processing
- complete retry or dead-letter queue parity
- managed EKS parity
- compliance readiness
- full compatibility with every AWS API operation

## Current one-line status

```text
The local AWS lab, Docker-backed event workflow, Floci restart persistence, and full Terraform create-to-destroy lifecycle are verified; the remaining major validation is a full Ubuntu VM reboot followed by a new message through the preserved manual event-driven stack.
```
