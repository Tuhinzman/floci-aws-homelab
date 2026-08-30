#!/usr/bin/env bash
set -euo pipefail

if [ "${EUID}" -eq 0 ]; then
  echo "Run this script as your normal Linux user, not with sudo."
  exit 1
fi

for required_command in aws-floci python3 sudo; do
  if ! command -v "$required_command" >/dev/null 2>&1; then
    echo "Missing required command: ${required_command}"
    exit 1
  fi
done

if ! sudo docker info >/dev/null 2>&1; then
  echo "Docker is not reachable through sudo."
  exit 1
fi

FUNCTION_NAME="${FLOCI_LAMBDA_FUNCTION:-floci-hello}"
ROLE_NAME="${FLOCI_LAMBDA_ROLE:-floci-lambda-role}"
RUNTIME="${FLOCI_LAMBDA_RUNTIME:-python3.13}"
HANDLER="lambda_function.handler"
ROLE_ARN="arn:aws:iam::000000000000:role/${ROLE_NAME}"
EXPECTED_MESSAGE="hello from Floci Lambda"
RUNTIME_IMAGE="public.ecr.aws/lambda/python:${RUNTIME#python}"
WORK_DIR="$(mktemp -d)"
trap 'rm -rf "$WORK_DIR"' EXIT

aws_local() {
  aws-floci \
    --cli-connect-timeout 10 \
    --cli-read-timeout 300 \
    "$@"
}

echo "============================================================"
echo "=== FLOCI LAMBDA SMOKE TEST ==="
echo "============================================================"

echo
echo "=== 1. PACKAGE FUNCTION ==="

cat >"${WORK_DIR}/lambda_function.py" <<'PY'
from typing import Any


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    return {
        "message": "hello from Floci Lambda",
        "received": event,
        "function_name": getattr(context, "function_name", None),
    }
PY

(
  cd "$WORK_DIR"
  python3 -m zipfile -c function.zip lambda_function.py
)

test -s "${WORK_DIR}/function.zip"
echo "FUNCTION_PACKAGE=PASS"

echo
echo "=== 2. CREATE EXECUTION ROLE ==="

cat >"${WORK_DIR}/trust-policy.json" <<'JSON'
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Principal": {
        "Service": "lambda.amazonaws.com"
      },
      "Action": "sts:AssumeRole"
    }
  ]
}
JSON

if aws_local iam get-role --role-name "$ROLE_NAME" >/dev/null 2>&1; then
  echo "ROLE_STATUS=ALREADY_PRESENT"
else
  aws_local iam create-role \
    --role-name "$ROLE_NAME" \
    --assume-role-policy-document "file://${WORK_DIR}/trust-policy.json" \
    >/dev/null
  echo "ROLE_STATUS=CREATED"
fi

ROLE_RESULT="$(
  aws_local iam get-role \
    --role-name "$ROLE_NAME" \
    --query 'Role.Arn' \
    --output text
)"

[ "$ROLE_RESULT" = "$ROLE_ARN" ]
echo "IAM_ROLE_TEST=PASS"

echo
echo "=== 3. CREATE FUNCTION ==="

if aws_local lambda get-function --function-name "$FUNCTION_NAME" >/dev/null 2>&1; then
  aws_local lambda delete-function --function-name "$FUNCTION_NAME"
  echo "OLD_TEST_FUNCTION=DELETED"
fi

aws_local lambda create-function \
  --function-name "$FUNCTION_NAME" \
  --runtime "$RUNTIME" \
  --role "$ROLE_ARN" \
  --handler "$HANDLER" \
  --zip-file "fileb://${WORK_DIR}/function.zip" \
  --timeout 15 \
  --memory-size 128 \
  >/dev/null

STATE="UNKNOWN"
LAST_UPDATE="UNKNOWN"

for attempt in $(seq 1 30); do
  STATE="$(
    aws_local lambda get-function-configuration \
      --function-name "$FUNCTION_NAME" \
      --query State \
      --output text 2>/dev/null || true
  )"

  LAST_UPDATE="$(
    aws_local lambda get-function-configuration \
      --function-name "$FUNCTION_NAME" \
      --query LastUpdateStatus \
      --output text 2>/dev/null || true
  )"

  echo "attempt=${attempt} state=${STATE:-UNKNOWN} last_update=${LAST_UPDATE:-UNKNOWN}"

  if [ "$STATE" = "Active" ] && {
    [ "$LAST_UPDATE" = "Successful" ] || [ "$LAST_UPDATE" = "None" ];
  }; then
    break
  fi

  sleep 1
done

[ "$STATE" = "Active" ]
echo "LAMBDA_CREATE_TEST=PASS"

echo
echo "=== 4. INVOKE FUNCTION ==="

aws_local lambda invoke \
  --function-name "$FUNCTION_NAME" \
  --payload '{"name":"learner","source":"floci-lambda-smoke-test"}' \
  --cli-binary-format raw-in-base64-out \
  "${WORK_DIR}/response.json" \
  >"${WORK_DIR}/invoke-metadata.json"

cat "${WORK_DIR}/invoke-metadata.json"
cat "${WORK_DIR}/response.json"
echo

python3 - \
  "${WORK_DIR}/invoke-metadata.json" \
  "${WORK_DIR}/response.json" \
  "$EXPECTED_MESSAGE" <<'PY'
import json
import sys
from pathlib import Path

metadata_path = Path(sys.argv[1])
response_path = Path(sys.argv[2])
expected_message = sys.argv[3]

metadata = json.loads(metadata_path.read_text())
response = json.loads(response_path.read_text())

if metadata.get("StatusCode") != 200:
    raise SystemExit(f"Unexpected status code: {metadata}")

if metadata.get("FunctionError"):
    raise SystemExit(f"Lambda returned FunctionError: {metadata}")

if response.get("message") != expected_message:
    raise SystemExit(f"Unexpected Lambda response: {response}")

expected_event = {
    "name": "learner",
    "source": "floci-lambda-smoke-test",
}

if response.get("received") != expected_event:
    raise SystemExit(f"Lambda event did not round-trip: {response}")

print("LAMBDA_RESPONSE_ASSERTION=PASS")
PY

echo "LAMBDA_INVOKE_TEST=PASS"

echo
echo "=== 5. VERIFY DOCKER EXECUTION ENVIRONMENT ==="

sudo docker ps \
  --format 'table {{.ID}}\t{{.Image}}\t{{.Names}}\t{{.Status}}'

LAMBDA_CONTAINER_ID="$(
  sudo docker ps \
    --filter "ancestor=${RUNTIME_IMAGE}" \
    --format '{{.ID}}' \
    | head -1
)"

if [ -z "$LAMBDA_CONTAINER_ID" ]; then
  echo "Expected a running Lambda container from ${RUNTIME_IMAGE}."
  exit 1
fi

NETWORKS="$(
  sudo docker inspect "$LAMBDA_CONTAINER_ID" \
    --format '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}} {{end}}'
)"

IMAGE="$(
  sudo docker inspect "$LAMBDA_CONTAINER_ID" \
    --format '{{.Config.Image}}'
)"

STATUS="$(
  sudo docker inspect "$LAMBDA_CONTAINER_ID" \
    --format '{{.State.Status}}'
)"

echo "LAMBDA_CONTAINER_ID=${LAMBDA_CONTAINER_ID}"
echo "LAMBDA_CONTAINER_IMAGE=${IMAGE}"
echo "LAMBDA_CONTAINER_STATUS=${STATUS}"
echo "LAMBDA_CONTAINER_NETWORKS=${NETWORKS}"

[ "$STATUS" = "running" ]
case " ${NETWORKS} " in
  *" floci_default "*) ;;
  *)
    echo "Lambda container is not attached to floci_default."
    exit 1
    ;;
esac

echo "LAMBDA_DOCKER_CONTAINER_TEST=PASS"

echo
echo "=== 6. FINAL RESOURCE READ-BACK ==="

aws_local lambda get-function-configuration \
  --function-name "$FUNCTION_NAME" \
  --query '{FunctionName:FunctionName,Runtime:Runtime,Handler:Handler,Role:Role,State:State}'

echo
echo "============================================================"
echo "FLOCI_LAMBDA_SMOKE_TEST=PASS"
echo "RESOURCES_LEFT_PRESENT=YES"
echo "============================================================"
