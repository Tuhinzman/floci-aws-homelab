# Project Status and Goals

Last updated: 2026-08-30

## Executive summary

This project is building a practical, low-cost AWS learning environment with Floci. It runs inside Docker on a dedicated Ubuntu virtual machine hosted by Proxmox.

The lab is designed for junior Cloud DevOps and Platform Engineers who need hands-on AWS-style experience but do not want every experiment to create a real AWS bill.

The project has already moved beyond a basic emulator installation. It now includes validated core services, Docker-backed Lambda execution, an event-driven SQS to Lambda to DynamoDB workflow, persistence testing, GitHub Actions validation, operator documentation, and an in-progress Terraform lifecycle.

The project does not claim that Floci is a complete replacement for AWS. Its purpose is to provide a safe and repeatable learning environment for development, testing, troubleshooting, and Infrastructure as Code practice before final validation in real AWS.

## Current status

The current overall status is:

```text
Platform foundation                         COMPLETE
Core AWS-style service validation           COMPLETE
Core-service restart persistence            COMPLETE
Docker-backed Lambda validation             COMPLETE
SQS to Lambda to DynamoDB integration       COMPLETE
Event-chain persistence after restart       COMPLETE
Repository documentation and CI             COMPLETE
Terraform static validation                 COMPLETE
Terraform plan and apply                    COMPLETE
Terraform post-apply functional validation  IN PROGRESS
Terraform destroy and cleanup proof         NOT YET EXECUTED
Full Ubuntu VM reboot validation             NOT YET EXECUTED
First portfolio release                     NOT YET FROZEN
```

## Validated lab environment

The reference environment currently uses:

```text
Hypervisor:       Proxmox VE / KVM
Guest OS:         Ubuntu 24.04 LTS
VM size:          6 vCPU, 16 GiB RAM, 80 GiB disk
Container engine: Docker Engine and Docker Compose
AWS emulator:     Floci 1.7.0
AWS client:       AWS CLI v2
IaC tool:         Terraform 1.16.0
Lambda runtime:   Python 3.13
```

Floci runs with hybrid persistent storage. Its main state is stored in a Docker volume, and the Docker socket is mounted so Floci can launch container-backed services such as Lambda runtimes.

The public repository does not contain the private VM address, MAC address, SSH material, machine IDs, local Terraform state, or raw private evidence.

## What has been completed

### 1. Proxmox and VM foundation

A dedicated Ubuntu VM was created instead of installing Docker directly on the Proxmox host.

The VM was validated for:

- CPU and memory allocation
- root filesystem expansion
- working DNS and Internet access
- QEMU guest agent operation
- discard and TRIM support
- SSH access
- Docker persistence across reboot

This keeps the experimental AWS lab isolated from the Proxmox host and makes it easier to rebuild or remove later.

### 2. Docker and Floci deployment

Docker Engine and Docker Compose were installed from Docker's official repository.

Floci 1.7.0 was deployed with:

- a pinned image version
- TCP port `4566`
- a persistent Docker volume
- hybrid storage mode
- Docker socket access for container-backed services
- an internal Docker hostname for service-to-service communication

The Floci container is running and reports healthy.

### 3. Isolated AWS CLI access

The project uses a dedicated AWS CLI profile named `floci` with dummy credentials.

A helper command named `aws-floci` always supplies the Floci endpoint and disables EC2 metadata lookup.

This reduces the risk of accidentally sending a learning command to a real AWS account.

### 4. Core service validation

The following workflows were executed and asserted end to end:

| Service | Validated workflow |
| --- | --- |
| STS | local identity and account read-back |
| S3 | create bucket, upload object, list object, read object |
| SQS | create queue, send message, receive message |
| DynamoDB | create table, put item, get item |
| SSM Parameter Store | put parameter, read parameter |
| Secrets Manager | create secret, read secret |

The tests verify returned values rather than only checking whether the command exited successfully.

### 5. Core-service persistence

Floci was restarted and the same S3 object, SQS queue, DynamoDB item, SSM parameter, and secret were read back successfully.

This proves persistence for the tested resources across a Floci container restart.

### 6. Docker-backed Lambda

A Python 3.13 Lambda function was packaged, created, and invoked through Floci.

The test verified:

- IAM role reference creation and read-back
- Lambda function state `Active`
- synchronous invocation status `200`
- exact request-event round trip
- exact response assertion
- a real Lambda runtime container using `public.ecr.aws/lambda/python:3.13`
- attachment of the runtime container to the `floci_default` Docker network

This is stronger than only checking that Lambda appears as `running` in the Floci health response.

### 7. Event-driven integration

The following complete workflow was validated:

```text
SQS message
→ Lambda event-source mapping
→ Docker-backed Lambda execution
→ DynamoDB PutItem
→ exact DynamoDB item read-back
```

The test asserted:

- queue ARN
- event-source mapping state `Enabled`
- Lambda function state `Active`
- returned SQS message ID
- DynamoDB `order_id`
- DynamoDB `status`
- DynamoDB `source`
- DynamoDB `processed_by`
- exact DynamoDB `message_id`

### 8. Event-chain persistence

The complete event-driven stack was then tested across a Floci restart.

The same SQS queue, DynamoDB table, Lambda function, and event-source mapping were read back after restart. The mapping retained the same UUID and remained enabled.

A new SQS message was sent after restart. It triggered a new Docker-backed Lambda execution and produced a new DynamoDB item with all expected fields.

### 9. GitHub repository and CI

The repository now contains:

- reusable Docker Compose configuration
- installation scripts
- AWS CLI isolation script
- core-service smoke tests
- persistence tests
- Lambda tests
- event-driven integration tests
- Terraform configuration
- architecture documentation
- an operator runbook
- troubleshooting notes
- sanitized validation records
- GitHub Actions validation

GitHub Actions currently checks:

- Bash syntax
- ShellCheck warnings
- Docker Compose rendering
- Terraform formatting
- Terraform provider initialization
- Terraform configuration validation
- repository safety files

## Current Terraform position

Terraform is the active milestone.

The Terraform stack defines six managed resources with names that are separate from the manually validated resources:

```text
DynamoDB table:       FlociTerraformOrders
SQS queue:            floci-terraform-orders
IAM role:             floci-terraform-orders-role
IAM inline policy:    floci-terraform-orders-policy
Lambda function:      floci-terraform-orders-processor
Event-source mapping: SQS to Lambda
```

The saved Terraform plan was verified as:

```text
6 to add
0 to change
0 to destroy
```

The exact six-resource create set matched the expected plan.

Terraform apply then completed successfully:

```text
6 added
0 changed
0 destroyed
```

The first post-apply validation stopped at a repository-script assertion. The script expected `terraform state list` to show only managed resources, but Terraform also listed three data sources:

```text
data.archive_file.lambda
data.aws_iam_policy_document.lambda_assume_role
data.aws_iam_policy_document.lambda_permissions
```

This was a validation-script issue, not a Terraform apply failure. The six managed resources remain present.

The repository now contains a corrected resume-validation path that separates managed resources from data sources. That validation has not yet been executed on the live lab.

Current Terraform boundary:

```text
Plan:                         PASS
Exact create set:             PASS
Apply:                        PASS
Managed resources present:    YES
Post-apply convergence:       PENDING
Functional event test:        PENDING
Destroy:                      NOT EXECUTED
Remote absence verification:  NOT EXECUTED
```

The next command should use the resume script rather than rerunning the initial create-plan workflow.

## Main goal of the project

The main goal is to create a reproducible, production-inspired local AWS learning platform where a learner can build, validate, operate, troubleshoot, and clean up AWS-style systems without depending on billable cloud infrastructure for every practice session.

The project should demonstrate the complete engineering lifecycle:

```text
prepare the platform
→ deploy the emulator
→ isolate credentials and endpoints
→ provision services
→ connect services into a real workflow
→ verify observable results
→ test persistence and recovery
→ manage the stack with Terraform
→ prove clean destruction
→ document the process clearly
```

## Detailed project objectives

### Objective 1: Make AWS learning affordable

A learner should be able to repeat experiments without worrying that a forgotten service, database, NAT gateway, cluster, or load balancer will create unexpected AWS charges.

Floci is used as a local practice environment. Real AWS remains the place for final validation when AWS-specific behavior matters.

### Objective 2: Teach workflows, not isolated commands

The project should not stop at examples such as `create-bucket` or `list-queues`.

It should teach connected workflows such as:

```text
message arrives
→ function is triggered
→ application code runs
→ data is written
→ result is read back
```

This helps learners understand dependencies, data flow, failure points, and observable outcomes.

### Objective 3: Use production-inspired operational practices

The lab should teach useful habits that transfer to real engineering work:

- dedicated runtime boundary
- pinned versions
- reusable configuration
- isolated credentials
- source-controlled scripts
- automated validation
- explicit health checks
- exact assertions
- persistent-state testing
- troubleshooting records
- safe cleanup
- clear claim boundaries

The goal is not to imitate every production control. It is to practice the reasoning and discipline behind reliable operations.

### Objective 4: Make the environment reproducible

A new learner should eventually be able to:

1. clone the repository
2. create or prepare an Ubuntu VM
3. install Docker and AWS CLI
4. configure Floci
5. run the validation sequence
6. provision the event-driven stack with Terraform
7. verify the workflow
8. destroy the Terraform-managed stack cleanly

The repository should be the source of truth, not a collection of one-time terminal history.

### Objective 5: Prove Infrastructure as Code lifecycle

The Terraform milestone is intended to prove:

```text
format
→ initialize providers
→ validate
→ create a saved plan
→ assert the exact change set
→ apply the saved plan
→ verify state
→ verify no-change convergence
→ run the event-driven functional test
→ create an exact destroy plan
→ destroy
→ prove managed state is empty
→ prove API resources are absent
```

This is one of the most important portfolio outcomes because it demonstrates lifecycle ownership rather than only resource creation.

### Objective 6: Build trustworthy evidence

Every verified claim should be supported by an executed test and an observable result.

The repository should distinguish among:

- supported by Floci documentation
- visible in the Floci health response
- statically validated in CI
- actually executed in the live lab
- persisted across restart
- destroyed and proven absent

This avoids exaggerated claims and makes the project credible during technical review.

### Objective 7: Produce useful documentation

The final documentation should help another engineer understand:

- why the project exists
- how the architecture works
- how to build the lab
- how to operate it
- how to validate it
- how to troubleshoot common problems
- what has been proven
- what remains outside the validation boundary

The runbook should remain practical and concise enough to use during real work.

### Objective 8: Create a strong portfolio project

The finished repository should show a hiring manager or senior engineer that the author can:

- design a safe lab environment
- work with Proxmox, Linux, Docker, AWS CLI, Lambda, SQS, DynamoDB, IAM references, and Terraform
- build event-driven systems
- automate repeatable tests
- troubleshoot failures without hiding them
- protect credentials and private infrastructure details
- document architecture and operations
- distinguish evidence from assumption
- complete plan, apply, validate, converge, and destroy workflows

## Definition of done

The project can be considered ready for its first stable portfolio release when all of the following are true:

- the documented setup can be reproduced from the repository
- Floci starts healthy from the Compose configuration
- core service smoke tests pass
- core resource persistence passes
- Docker-backed Lambda passes
- SQS to Lambda to DynamoDB passes
- event-chain persistence after Floci restart passes
- Terraform static validation passes in GitHub Actions
- Terraform exact create plan passes
- Terraform apply passes
- Terraform no-change convergence passes
- Terraform-managed event workflow passes
- Terraform exact destroy plan passes
- Terraform destroy passes
- managed Terraform state is empty after destroy
- Terraform-managed API resources are proven absent
- the manually validated reference resources remain untouched
- a full Ubuntu VM reboot test passes
- public documentation contains no private addresses, credentials, machine IDs, or raw secrets
- the final GitHub Actions run is green
- a versioned release is tagged with a clear validation boundary

## Roadmap from the current point

### Immediate next step

Run the corrected Terraform resume validation against the six resources that are already present.

Expected outcome:

```text
managed state exact match
expected data sources present
no-change Terraform convergence
Lambda function active
event-source mapping enabled
new SQS message processed
new DynamoDB item asserted
Docker-backed runtime verified
```

### Next step after resume validation

Run the guarded Terraform destroy workflow:

```text
exact six-resource destroy plan
→ apply saved destroy plan
→ managed Terraform state empty
→ SQS absent
→ DynamoDB absent
→ Lambda absent
→ IAM role absent
→ event-source mapping absent
→ Terraform Lambda runtime container absent
```

### Final persistence boundary

Restart the full Ubuntu VM and verify:

- Docker starts
- Floci becomes healthy
- the manual event-driven stack still exists
- a new message still triggers Lambda
- a new DynamoDB item is written

This is intentionally separate from the Terraform destroy test because Terraform-managed resources should be cleaned up before the stable release boundary.

### Release preparation

After all validations pass:

- update README status
- add final sanitized validation records
- review all scripts and docs
- confirm CI is green
- create a version tag and GitHub release
- include exact verified and unverified claims

## Non-goals and limitations

This project is not intended to prove:

- exact AWS IAM authorization enforcement
- real VPC, subnet, route, NAT, or security-group behavior
- Multi-AZ availability
- AWS service quotas
- production performance or scaling
- exactly-once SQS processing
- complete retry and dead-letter queue parity
- managed EKS parity
- compliance readiness
- full compatibility with every AWS API operation

Those areas require real AWS or a purpose-built production test environment.

## Working principles

The project follows these rules:

1. Prefer simple designs before adding more tools.
2. Define the expected result before running a change.
3. Do not call a service validated only because it appears in a health list.
4. Use exact assertions whenever possible.
5. Preserve evidence without publishing private infrastructure details.
6. Keep manual and Terraform-managed resource names separate.
7. Do not destroy resources until the active validation milestone is reviewed.
8. Document failures and fixes, not only successful commands.
9. Stop expanding scope when the current lifecycle is not yet complete.
10. Use real AWS for final proof when the claim depends on real AWS behavior.

## Current one-line status

```text
The local AWS platform and event-driven workflow are fully validated across a Floci restart; Terraform successfully created its separate six-resource stack, and the project is now waiting for corrected post-apply functional validation before guarded destroy and final release work.
```
