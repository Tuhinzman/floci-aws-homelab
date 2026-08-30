#!/usr/bin/env bash
set -euo pipefail

if [ "${EUID}" -ne 0 ]; then
  echo "Run this script with sudo or as root."
  exit 1
fi

apt-get update
apt-get install -y curl unzip

if command -v aws >/dev/null 2>&1; then
  echo "AWS CLI is already installed:"
  aws --version
  exit 0
fi

curl -fsSL https://awscli.amazonaws.com/v2/install.sh | bash -s -- --system

command -v aws
aws --version
