# Project Status and Goals

Last updated: 2026-08-31 UTC / 2026-08-30 EDT

## Executive summary

This project builds a practical, low-cost AWS learning environment with Floci. It runs in Docker on a dedicated Ubuntu virtual machine hosted by Proxmox.

The lab is designed for junior Cloud DevOps and Platform Engineers who need hands-on AWS-style experience without making every experiment dependent on billable AWS infrastructure.

The project has moved beyond a basic emulator installation. It now includes validated core services, persistent state, Docker-backed Lambda execution, a complete SQS to Lambda to DynamoDB workflow, restart testing, Infrastructure as Code with Terraform, GitHub Actions validation, an operator runbook, troubleshooting notes, and sanitized evidence records.

The project does not claim that Floci is a complete replacement for AWS. It is a safe and repeatable environment for learning, development, integration testing, troubleshooting, and Terraform lifecycle practice before AWS-specific claims are validated in real AWS.

## Current status

```text
Platform foundation                         COMPLETE
Core AWS-style service validation           COMPLETE
Core-service restart persistence            COMPLETE
Docker-backed Lambda validation             COMPLETE
SQS to Lambda to DynamoDB integration       COMPLETE
Event-chain persistence after restart       COMPLETE
Repository documentation and CI             COMPLETE
Terraform static validation                 COMPLETE
Terraform exact create plan                 COMPLETE
Terraform saved-plan apply                  COMPLETE
Terraform managed/data state validation     COMPLETE
Terraform no-change convergence             COMPLETE
Terraform functional event validation       COMPLETE
Terraform destroy and cleanup proof         NOT YET EXECUTED
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

Floci uses hybrid persistent storage. Its state is stored in a Docker volume, and the Docker socket is mounted so Floci can start container-backed services such as Lambda runtimes.

The public repository does not contain the private VM address, MAC address, SSH material, machine IDs, local Terraform state, local tfvars, saved plans, or raw private evidence.

## What has been completed

### 1. Proxmox and VM foundation

A dedicated Ubuntu VM was created instead of installing Docker directly on the Proxmox host.

The VM was validated for:

- CPU and memory allocation
- root filesystem expansion
- DNS and Internet access
- SSH access
- QEMU guest agent operation
- discard and TRIM support
- Docker startup after a guest reboot

This creates a separate failure boundary and keeps the experimental lab away from the Proxmox host operating environment.

### 2. Docker and Floci deployment

Docker Engine and Docker Compose were installed from Docker's official repository.

Floci 1.7.0 was deployed with:

- a pinned image version
- TCP port `4566`
- a persistent Docker volume
- hybrid storage mode
- Docker socket access
- an internal Docker hostname for service containers

The Floci container is running and healthy.

### 3. Isolated AWS CLI access

The project uses a dedicated AWS CLI profile named `floci` with dummy credentials.

The `aws-floci` helper always supplies the local endpoint and disables EC2 metadata lookup. This reduces the risk of accidentally sending lab commands to a real AWS account.

### 4. Core service validation

The following workflows were executed and asserted end to end:

| Service | Validated workflow |
| --- | --- |
| STS | local account and identity read-back |
| S3 | create bucket, upload, list, and read object |
| SQS | create queue, send, and receive message |
| DynamoDB | create table, put item, and get item |
| SSM Parameter Store | put and read parameter |
| Secrets Manager | create and read secret |

The tests verify returned values, not only command exit codes.

### 5. Core-service persistence

Floci was restarted and the same S3 object, SQS queue, DynamoDB item, SSM parameter, and secret were read back successfully.

### 6. Docker-backed Lambda

A Python 3.13 function was packaged, created, and invoked through Floci.

The test verified:

- IAM role-reference creation and read-back
- function state `Active`
- synchronous invocation status `200`
- exact input-event round trip
- exact response assertion
- real runtime image `public.ecr.aws/lambda/python:3.13`
- runtime attachment to `floci_default`

### 7. Event-driven integration

The following complete path was validated:

```text
SQS message
→ Lambda event-source mapping
→ Docker-backed Lambda execution
→ DynamoDB PutItem
→ exact item read-back
```

The test asserted the queue ARN, mapping state, function state, SQS message ID, and every expected DynamoDB field.

### 8. Event-chain restart persistence

After restarting Floci, the same queue, table, function, and event-source mapping were read back. The mapping retained the same UUID and remained enabled.

A new SQS message then triggered a new Docker-backed Lambda execution and produced a new asserted DynamoDB item.

### 9. GitHub repository and CI

The repository includes:

- reusable Docker Compose configuration
- installation and configuration scripts
- AWS CLI isolation
- core, Lambda, event-driven, and persistence tests
- Terraform configuration and lifecycle scripts
- architecture documentation
- operator runbook
- troubleshooting notes
- sanitized validation records
- GitHub Actions validation

GitHub Actions checks:

- Bash syntax
- ShellCheck
- Docker Compose rendering
- Terraform formatting
- provider initialization
- Terraform validation
- repository safety files

## Current Terraform position

Terraform manages a separate six-resource stack so the earlier manual evidence stack remains untouched:

```text
DynamoDB table:       FlociTerraformOrders
SQS queue:            floci-terraform-orders
IAM role:             floci-terraform-orders-role
IAM inline policy:    floci-terraform-orders-policy
Lambda function:      floci-terraform-orders-processor
Event-source mapping: SQS to Lambda
```

### Plan and apply

The saved plan was verified as:

```text
6 to add
0 to change
0 to destroy
```

The exact six-resource create set matched the expected plan.

The saved plan applied successfully:

```text
6 added
0 changed
0 destroyed
```

### Original post-apply issue

The first post-apply validation stopped because the script compared all entries from `terraform state list` against only the six managed resources.

Terraform also listed three expected data resources:

```text
data.archive_file.lambda
data.aws_iam_policy_document.lambda_assume_role
data.aws_iam_policy_document.lambda_permissions
```

This was a script assertion issue, not an apply failure.

### Corrected resume validation

The corrected resume workflow separated managed resources from data resources and passed:

```text
TERRAFORM_MANAGED_STATE_EXACT_MATCH=PASS
TERRAFORM_DATA_STATE_EXACT_MATCH=PASS
```

A refresh plan returned:

```text
No changes. Your infrastructure matches the configuration.
TERRAFORM_CONVERGENCE=PASS
```

The resume test then verified:

```text
Lambda function state       = Active
Event-source mapping state  = Enabled
SQS message send            = PASS
DynamoDB side effect        = PASS
Exact item assertions       = PASS
Lambda container state      = running
Lambda container network    = floci_default
```

Final observed boundary:

```text
Plan:                         PASS
Exact create set:             PASS
Apply:                        PASS
Managed state exact match:    PASS
Data state exact match:       PASS
No-change convergence:        PASS
Functional event test:        PASS
Resources still present:      YES
Destroy:                      NOT EXECUTED
Remote absence verification:  NOT EXECUTED
```

The sanitized validation record is:

```text
docs/validation/v0.5-terraform-apply-and-convergence.md
```

## Main project goal

Create a reproducible, production-inspired local AWS learning platform where a learner can build, validate, operate, troubleshoot, and clean up AWS-style systems without depending on billable cloud infrastructure for every practice session.

The project demonstrates this engineering lifecycle:

```text
prepare the platform
→ deploy the emulator
→ isolate credentials and endpoints
→ provision services
→ connect services into a real workflow
→ verify observable results
→ test persistence and recovery
→ manage the stack with Terraform
→ prove no-change convergence
→ prove clean destruction
→ document the process clearly
```

## Detailed objectives

### Make AWS learning affordable

Learners should be able to repeat experiments without worrying that forgotten AWS resources will create unexpected charges. Real AWS remains necessary when the claim depends on real AWS behavior.

### Teach connected workflows

The project teaches service relationships, not isolated commands:

```text
message arrives
→ function is triggered
→ application code runs
→ data is written
→ result is read back
```

### Practice production-inspired habits

The lab reinforces:

- dedicated runtime boundaries
- pinned versions
- reusable configuration
- isolated credentials
- source-controlled scripts
- automated checks
- exact assertions
- persistence testing
- safe cleanup
- honest claim boundaries

### Make the environment reproducible

A new learner should eventually be able to clone the repository, prepare an Ubuntu VM, install the tools, start Floci, run the tests, provision the Terraform stack, verify it, and destroy it cleanly.

### Prove the complete Terraform lifecycle

The Terraform milestone requires:

```text
format
→ init
→ validate
→ saved plan
→ exact change-set assertion
→ apply saved plan
→ managed/data state validation
→ no-change convergence
→ functional event validation
→ exact destroy plan
→ saved-plan destroy
→ managed state empty
→ API resources absent
```

### Build trustworthy evidence

The project distinguishes among:

- documented by Floci
- listed in health output
- statically validated in CI
- executed in the live lab
- persisted across restart
- destroyed and proven absent

### Produce useful documentation

Documentation should explain why the lab exists, how it works, how to build and operate it, how to troubleshoot it, what has been proven, and what remains outside the claim boundary.

### Create a credible portfolio project

The final repository should demonstrate practical work with Proxmox, Linux, Docker, AWS CLI, SQS, Lambda, DynamoDB, IAM references, Terraform, CI, testing, troubleshooting, evidence, and operational documentation.

## Definition of done

The first stable portfolio release requires:

- reproducible documented setup
- healthy Floci deployment
- passing core-service tests
- passing core persistence
- passing Docker-backed Lambda
- passing event-driven integration
- passing event-chain restart persistence
- passing Terraform static validation
- passing exact create plan and saved-plan apply
- passing exact managed/data state validation
- passing no-change convergence
- passing Terraform-managed functional workflow
- passing exact destroy plan and destroy
- empty managed Terraform state after destroy
- API absence proof for all Terraform-managed resources
- manual reference resources left untouched
- successful full Ubuntu VM reboot validation
- public security and privacy review
- final green GitHub Actions run
- versioned release with clear verified and unverified boundaries

## Roadmap from the current point

### Next lifecycle step

The Terraform-managed stack is fully validated and still present.

The next technical step is the guarded destroy workflow:

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

Destroy must not run until the owner explicitly authorizes it.

### Final persistence boundary

After the Terraform-managed resources are cleaned up, restart the full Ubuntu VM and verify that Docker, Floci, and the manually validated event-driven reference stack recover and process a new message.

### Release preparation

After all validations pass:

- update README and validation records
- review scripts and documentation
- confirm CI is green
- inspect the public repository for private data
- create a version tag and GitHub release
- publish exact verified and unverified claims

## Non-goals and limitations

This project does not prove:

- exact AWS IAM authorization enforcement
- real VPC, subnet, route, NAT, or security-group behavior
- Multi-AZ availability
- AWS quotas
- production performance or scaling
- exactly-once SQS processing
- complete retry or dead-letter queue parity
- managed EKS parity
- compliance readiness
- full compatibility with every AWS API operation

## Working principles

1. Prefer simple designs.
2. Define success before execution.
3. Require observable evidence for claims.
4. Keep manual and Terraform-managed resources separate.
5. Do not publish private infrastructure data.
6. Do not destroy before review and explicit authorization.
7. Document failures and fixes.
8. Finish the current lifecycle before expanding scope.
9. Use real AWS when the claim depends on real AWS.

## Current one-line status

```text
The local AWS platform, Docker-backed event workflow, restart persistence, and Terraform-managed event stack are fully validated through no-change convergence and functional execution; the Terraform resources remain present, and guarded destroy is the next lifecycle step but is not yet authorized.
```
