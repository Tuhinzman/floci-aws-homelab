# Architecture

This lab runs Floci inside a dedicated Ubuntu virtual machine on Proxmox rather than installing Docker directly on the Proxmox host.

```text
Bare-metal server
└── Proxmox VE
    └── Ubuntu 24.04 VM
        ├── Docker Engine
        │   └── Floci 1.7.0
        │       ├── persistent Floci volume
        │       └── Docker socket for container-backed services
        └── AWS CLI v2
            └── floci profile + aws-floci wrapper
```

## Why a VM instead of the Proxmox host?

Keeping Docker and Floci inside a VM gives the lab its own failure boundary. A broken container, package update, or experimental service does not modify the Proxmox host itself.

It also makes the environment easier to rebuild, resize, snapshot when appropriate, or remove later.

## Starting VM size

The validated lab started with:

- 6 vCPU
- 16 GiB RAM
- 80 GiB virtual disk
- Ubuntu 24.04 LTS

This is not a minimum requirement. Lightweight services can run with less. Heavier services such as local Kubernetes, Kafka, OpenSearch, databases, or multiple Lambda workloads can require more memory and disk.

## Network model

Floci exposes its main AWS-compatible API on TCP port `4566`.

The public repository does not hard-code the author's private LAN address. Set `FLOCI_HOST_IP` in `.env` to the address assigned to your VM.

```text
Workstation
    |
    | TCP 4566
    v
Ubuntu VM
    |
    v
Floci
```

For a home lab, a DHCP reservation is usually preferable to manually placing an arbitrary static address inside the guest. It keeps the address stable while allowing the router to remain the source of truth for the subnet and gateway.

## Storage model

The lab uses Floci `hybrid` storage with a Docker volume mounted at `/app/data`.

```text
Floci container
    |
    +-- /app/data
          |
          +-- Docker volume: floci-data
```

The tested S3, SQS, DynamoDB, SSM Parameter Store, and Secrets Manager resources survived a Floci container restart.

The Docker socket is also mounted into Floci because some emulated services create additional local containers. Treat access to the Docker socket as privileged access to the VM.

## AWS CLI isolation

The lab does not use real AWS access keys.

```text
AWS profile: floci
Access key:  test
Secret key:  test
Endpoint:    http://<FLOCI_HOST_IP>:4566
```

The `aws-floci` wrapper always supplies the Floci endpoint and disables EC2 metadata lookup. This reduces the chance of accidentally sending a learning command to a real AWS account.

## Validation boundary

The following workflows have been executed successfully:

- STS identity lookup
- S3 create, upload, list, and read
- SQS create, send, and receive
- DynamoDB create, write, and read
- SSM parameter create and read
- Secrets Manager secret create and read
- persistence of all of the above across a Floci restart

Other services may appear as running in Floci's health endpoint, but they are not considered validated in this repository until an end-to-end workflow has been executed and documented.
