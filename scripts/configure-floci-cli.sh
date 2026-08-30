#!/usr/bin/env bash
set -euo pipefail

FLOCI_HOST_IP="${FLOCI_HOST_IP:-}"
FLOCI_REGION="${FLOCI_REGION:-us-east-1}"

if [ -z "$FLOCI_HOST_IP" ]; then
  echo "Set FLOCI_HOST_IP first, for example:"
  echo "  export FLOCI_HOST_IP=192.168.1.50"
  exit 1
fi

mkdir -p "$HOME/.aws"
chmod 700 "$HOME/.aws"

cat >"$HOME/.aws/config" <<EOF
[profile floci]
region = ${FLOCI_REGION}
output = json
EOF

cat >"$HOME/.aws/credentials" <<'EOF'
[floci]
aws_access_key_id = test
aws_secret_access_key = test
EOF

chmod 600 "$HOME/.aws/config" "$HOME/.aws/credentials"

sudo tee /usr/local/bin/aws-floci >/dev/null <<EOF
#!/usr/bin/env bash
set -e
export AWS_EC2_METADATA_DISABLED=true
exec /usr/local/bin/aws --profile floci --endpoint-url http://${FLOCI_HOST_IP}:4566 "\$@"
EOF

sudo chmod 755 /usr/local/bin/aws-floci

aws configure list --profile floci
aws-floci sts get-caller-identity
