#!/usr/bin/env bash
set -euo pipefail

if [ "${EUID}" -eq 0 ]; then
  echo "Run this script as your normal Linux user, not with sudo."
  exit 1
fi

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${FLOCI_ENV_FILE:-${REPO_ROOT}/.env}"

if [ -f "$ENV_FILE" ]; then
  set -a
  # shellcheck disable=SC1090
  . "$ENV_FILE"
  set +a
fi

FLOCI_HOST_IP="${FLOCI_HOST_IP:-}"
FLOCI_REGION="${FLOCI_REGION:-us-east-1}"

if [ -z "$FLOCI_HOST_IP" ]; then
  echo "FLOCI_HOST_IP is not set."
  echo "Copy .env.example to .env and set the VM address first."
  exit 1
fi

AWS_BIN="$(command -v aws || true)"

if [ -z "$AWS_BIN" ]; then
  echo "AWS CLI was not found. Run scripts/install-aws-cli.sh first."
  exit 1
fi

mkdir -p "$HOME/.aws"
chmod 700 "$HOME/.aws"

# Use AWS CLI configuration commands so existing profiles are preserved.
aws configure set region "$FLOCI_REGION" --profile floci
aws configure set output json --profile floci
aws configure set aws_access_key_id test --profile floci
aws configure set aws_secret_access_key test --profile floci

chmod 600 "$HOME/.aws/config" "$HOME/.aws/credentials"

sudo tee /usr/local/bin/aws-floci >/dev/null <<EOF
#!/usr/bin/env bash
set -euo pipefail
export AWS_EC2_METADATA_DISABLED=true
exec ${AWS_BIN} \
  --profile floci \
  --endpoint-url http://${FLOCI_HOST_IP}:4566 \
  "\$@"
EOF

sudo chmod 755 /usr/local/bin/aws-floci

aws configure list --profile floci
aws-floci sts get-caller-identity
