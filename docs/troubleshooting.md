# Troubleshooting

These are real issues encountered while building the lab. They are kept here because they are exactly the kind of small problems that can waste time when you are learning.

## SSH says the remote host identification changed

Example:

```text
WARNING: REMOTE HOST IDENTIFICATION HAS CHANGED!
```

This usually happens when an IP address was previously used by another VM or device and your workstation still has the old SSH host key saved.

Do not blindly delete the key first. Verify the new VM's ED25519 fingerprint from the hypervisor or VM console, compare it with the fingerprint shown by SSH, then remove the old entry if they match.

```bash
ssh-keygen -R <VM_IP>
ssh <user>@<VM_IP>
```

## AWS CLI installer says `unzip` is missing

The official AWS CLI v2 installer needs `unzip`.

```bash
sudo apt-get update
sudo apt-get install -y unzip
```

The repository installer script handles this automatically.

## `The config profile (floci) could not be found`

A common cause is running an AWS command inside:

```bash
sudo bash
```

The `floci` profile is normally stored under the regular user's home directory, for example:

```text
/home/<user>/.aws/config
/home/<user>/.aws/credentials
```

When the whole shell runs under sudo, `$HOME` changes and AWS CLI looks for root's profile instead.

Run AWS CLI commands as the normal user. Use `sudo` only for the Docker commands that need it.

## Floci is healthy but `curl http://127.0.0.1:4566` fails

If Compose publishes the port to one specific VM address:

```yaml
ports:
  - "${FLOCI_HOST_IP}:4566:4566"
```

then Docker is not listening on `127.0.0.1:4566`.

Use the configured VM address:

```bash
curl -fsS "http://${FLOCI_HOST_IP}:4566/_localstack/health"
```

You can confirm the bind with:

```bash
ss -lntp | grep ':4566'
```

## Cloud-init reports `degraded done`

Check the detailed output instead of assuming the VM failed:

```bash
cloud-init status --long
```

In the validated build, cloud-init reported no actual errors. The degraded state came from a deprecation warning for older `user` syntax in the template.

Treat warnings and errors differently. If `errors: []` and the required VM configuration was applied correctly, a deprecation warning is not necessarily a blocker.

## Proxmox warns that thin volume sizes exceed the thin pool

Example:

```text
WARNING: Sum of all thin volume sizes exceeds the size of thin pool
```

This is possible with LVM-thin because virtual disks are thin-provisioned. Their logical sizes can add up to more than the physical storage pool.

The warning is not the same as an immediate disk failure, but it matters. Monitor actual thin-pool usage and leave enough physical headroom for running VMs to grow.

Useful checks on the Proxmox host:

```bash
pvesm status
lvs -a -o vg_name,lv_name,lv_size,data_percent,metadata_percent,lv_attr
```

Do not size a new lab only from the logical disk totals.

## The VM disk was enlarged but the filesystem is still small

Check both the virtual block device and the mounted filesystem:

```bash
lsblk
df -hT /
```

Cloud images often grow the root partition automatically through cloud-init, but verify it instead of assuming it happened.

## Docker is installed but the running kernel is older than the newly installed kernel

Package installation can install a newer kernel without switching the currently running kernel.

Check:

```bash
uname -r
```

If the package manager indicates a newer kernel is installed, reboot the VM once and verify Docker returns after boot:

```bash
sudo reboot
```

Then:

```bash
uname -r
systemctl is-active docker
```

## S3 `ls` returns no output

An empty result is not necessarily an error. If no buckets exist, this is valid:

```bash
aws-floci s3 ls
```

Create a test bucket or run the smoke test before expecting output.

## Floci health lists a service as `running`

Do not interpret this as proof that every AWS operation for that service works.

Health means the service API is enabled in Floci. Validate the specific workflow you care about before depending on it or documenting it as tested.

## Docker Compose cannot find the Floci project

The validated VM kept its operational Compose configuration under:

```text
/opt/floci
```

The public repository keeps the reusable template under `compose/`.

For the persistence script, either deploy the Compose project to `/opt/floci` or set:

```bash
export FLOCI_DIR=/path/to/your/floci/project
```

before running the test.
