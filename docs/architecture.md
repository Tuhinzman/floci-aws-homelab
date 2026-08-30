# Architecture

This lab runs Floci inside a dedicated Ubuntu virtual machine on Proxmox. Docker is kept inside the VM rather than installed on the Proxmox host.

```text
Bare-metal server
└── Proxmox VE
    └── Ubuntu 24.04 VM
        ├── Docker Engine
        │   ├── Floci 1.7.0
        │   │   ├── persistent data volume
        │   │   ├── AWS-compatible API on TCP 4566
        │   │   └── SQS event-source mappings
        │   └── Python 3.13 Lambda runtime containers
        │       └── floci_default network
        └── AWS CLI v2
            └── isolated floci profile and aws-floci wrapper
```

## Why use a VM?

The VM provides a separate failure boundary. Package changes, Docker experiments, and service failures stay away from the Proxmox host. The environment can also be resized, rebuilt, or removed independently.

The validated VM started with:

- 6 vCPU
- 16 GiB RAM
- 80 GiB virtual disk
- Ubuntu 24.04 LTS

This is a practical starting point, not a minimum requirement.

## Network model

The VM shell and workstation reach Floci through the private VM address:

```text
http://<FLOCI_HOST_IP>:4566
```

Lambda runtime containers reach Floci through the Compose network:

```text
http://floci:4566
```

The `.env` file therefore contains two related settings:

```text
FLOCI_HOST_IP=<private VM address>
FLOCI_INTERNAL_HOSTNAME=floci
```

The Lambda tests confirmed that the runtime containers joined `floci_default`. This allows a function to call local services such as DynamoDB through Docker DNS.

Because Floci uses the internal hostname when it returns absolute service URLs, SQS queue URLs use this form:

```text
http://floci:4566/000000000000/<queue-name>
```

A DHCP reservation is recommended so the VM address stays stable.

## Storage model

Floci uses hybrid storage with a Docker volume mounted at `/app/data`:

```text
Floci container
└── /app/data
    └── floci_floci-data
```

The tested S3, SQS, DynamoDB, SSM Parameter Store, and Secrets Manager resources survived a Floci container restart.

The Docker socket is mounted into Floci so container-backed services can start local runtimes. The Lambda tests used that socket to run the Python 3.13 Lambda image. Docker-socket access should be treated as privileged access to the VM.

## Validated synchronous Lambda path

```text
Python source
→ ZIP package
→ Lambda API
→ execution-role reference
→ Docker-backed Python 3.13 runtime
→ synchronous invocation
→ response assertion
```

The validation confirmed the expected runtime image, a running container, attachment to `floci_default`, and exact request and response values.

## Validated event-driven path

```text
SQS message
→ enabled event-source mapping
→ Lambda: floci-orders-processor
→ Docker-backed Python execution
→ DynamoDB PutItem
→ exact item read-back
```

The function writes the following fields:

- `order_id`
- `status`
- `source`
- `message_id`
- `processed_by`

The test asserted every field. It did not merely check that the table contained an item.

## Verified boundary

The repository currently verifies:

- STS identity lookup
- S3 create, write, list, and read
- SQS create, send, and receive
- DynamoDB create, write, and read
- SSM parameter create and read
- Secrets Manager secret create and read
- core-service persistence across a Floci restart
- Python 3.13 Lambda creation and synchronous invocation
- Docker-backed Lambda execution
- SQS event-source mapping creation and `Enabled` state
- asynchronous SQS-triggered Lambda execution
- Lambda-to-DynamoDB write and exact read-back

It does not yet verify:

- persistence of the Lambda function or event-source mapping after a Floci restart
- processing after a full VM reboot
- retry or dead-letter queue behavior
- partial batch failure handling
- exactly-once delivery
- production scaling, availability, or AWS IAM parity

A separate script is included to test the complete event-driven path after restarting Floci. That result should only be added to the verified boundary after the script passes on the lab.
