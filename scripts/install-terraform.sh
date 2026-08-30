#!/usr/bin/env bash
set -euo pipefail

if [ "${EUID}" -ne 0 ]; then
  echo "Run this script with sudo or as root."
  exit 1
fi

TERRAFORM_VERSION="${TERRAFORM_VERSION:-1.16.0}"
INSTALL_DIR="${TERRAFORM_INSTALL_DIR:-/usr/local/bin}"
MACHINE_ARCH="$(uname -m)"

case "$MACHINE_ARCH" in
  x86_64 | amd64)
    TERRAFORM_ARCH="amd64"
    ;;
  aarch64 | arm64)
    TERRAFORM_ARCH="arm64"
    ;;
  *)
    echo "Unsupported architecture: ${MACHINE_ARCH}"
    exit 1
    ;;
esac

if command -v terraform >/dev/null 2>&1; then
  CURRENT_VERSION="$(
    terraform version -json 2>/dev/null |
      python3 -c 'import json,sys; print(json.load(sys.stdin)["terraform_version"])' \
      2>/dev/null || true
  )"

  if [ "$CURRENT_VERSION" = "$TERRAFORM_VERSION" ]; then
    terraform version
    echo "TERRAFORM_INSTALL=ALREADY_PRESENT"
    exit 0
  fi

  echo "Replacing Terraform ${CURRENT_VERSION:-unknown} with ${TERRAFORM_VERSION}."
fi

apt-get update
apt-get install -y ca-certificates curl unzip

WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

ZIP_NAME="terraform_${TERRAFORM_VERSION}_linux_${TERRAFORM_ARCH}.zip"
CHECKSUM_NAME="terraform_${TERRAFORM_VERSION}_SHA256SUMS"
BASE_URL="https://releases.hashicorp.com/terraform/${TERRAFORM_VERSION}"

curl -fsSLo "${WORK_DIR}/${ZIP_NAME}" \
  "${BASE_URL}/${ZIP_NAME}"

curl -fsSLo "${WORK_DIR}/${CHECKSUM_NAME}" \
  "${BASE_URL}/${CHECKSUM_NAME}"

grep " ${ZIP_NAME}\$" \
  "${WORK_DIR}/${CHECKSUM_NAME}" \
  >"${WORK_DIR}/${ZIP_NAME}.sha256"

(
  cd "$WORK_DIR"
  sha256sum -c "${ZIP_NAME}.sha256"
  unzip -q "$ZIP_NAME"
)

install -m 0755 \
  "${WORK_DIR}/terraform" \
  "${INSTALL_DIR}/terraform"

terraform version

INSTALLED_VERSION="$(
  terraform version -json |
    python3 -c 'import json,sys; print(json.load(sys.stdin)["terraform_version"])'
)"

if [ "$INSTALLED_VERSION" != "$TERRAFORM_VERSION" ]; then
  echo "Terraform version verification failed."
  exit 1
fi

echo "TERRAFORM_INSTALL=PASS"
