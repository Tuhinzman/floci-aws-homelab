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

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ENV_FILE="${FLOCI_ENV_FILE:-${REPO_ROOT}/.env}"

if [ ! -f "$ENV_FILE" ]; then
  echo "Missing ${ENV_FILE}. Copy .env.example to .env and configure it first."
  exit 1
fi

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

: "${FLOCI_INTERNAL_HOSTNAME:?FLOCI_INTERNAL_HOSTNAME is required in .env}"

FUNCTION_NAME="${FLOCI_EVENT_FUNCTION:-floci-orders-processor}"
ROLE_NAME="${FLOCI_EVENT_ROLE:-floci-orders-role}"
POLICY_NAME="${FLOCI_EVENT_POLICY:-floci-orders-policy}"
QUEUE_NAME="${FLOCI_EVENT_QUEUE:-floci-orders-events}"
TABLE_NAME="${FLOCI_EVENT_TABLE:-FlociOrders}"
RUNTIME="${FLOCI_EVENT_RUNTIME:-python3.13}"
HANDLER="lambda_function.handler"
REGION="${FLOCI_REGION:-us-east-1}"
ACCOUNT_ID="000000000000"
ROLE_ARN="arn:aws:iam::${ACCOUNT_ID}:role/${ROLE_NAME}"
TABLE_ARN="arn:aws:dynamodb:${REGION}:${ACCOUNT_ID}:table/${TABLE_NAME}"
RUNTIME_IMAGE="public.ecr.aws/lambda/python:${RUNTIME#python}"
INTERNAL_ENDPOINT="http://${FLOCI_INTERNAL_HOSTNAME}:4566"
RUN_ID="order-$(date -u +%Y%m%dT%H%M%SZ)-$$"
EXPECTED_STATUS="created"
WORK_DIR="$(mktemp -d)"
QUEUE_URL=""
MAPPING_UUID=""

cleanup() {
  rm -rf "$WORK_DIR"
}

aws_local() {
  aws-floci \
    --cli-connect-timeout 10 \
    --cli-read-timeout 300 \
    "$@"
}

diagnostics() {
  local exit_code=$?
  set +e

  echo
  echo "============================================================"
  echo "=== EVENT-DRIVEN TEST DIAGNOSTICS ==="
  echo "============================================================"

  if [ -n "$MAPPING_UUID" ]; then
    aws_local lambda get-event-source-mapping --uuid "$MAPPING_UUID"
  else
    aws_local lambda list-event-source-mappings \
      --function-name "$FUNCTION_NAME"
  fi

  if [ -n "$QUEUE_URL" ]; then
    aws_local sqs get-queue-attributes \
      --queue-url "$QUEUE_URL" \
      --attribute-names All
  fi

  aws_local lambda get-function-configuration \
    --function-name "$FUNCTION_NAME"

  sudo docker ps \
    --format 'table {{.ID}}\t{{.Image}}\t{{.Names}}\t{{.Status}}\t{{.Networks}}'

  sudo docker logs --since 5m floci 2>&1 | tail -200

  echo "EVENT_DRIVEN_TEST=FAIL"
  exit "$exit_code"
}

trap cleanup EXIT
trap diagnostics ERR

assert_equals() {
  local label="$1"
  local expected="$2"
  local actual="$3"

  if [ "$actual" != "$expected" ]; then
    echo "${label}=FAIL" >&2
    echo "Expected: ${expected}" >&2
    echo "Actual:   ${actual}" >&2
    return 1
  fi

  echo "${label}=PASS"
}

echo "============================================================"
echo "=== FLOCI SQS -> LAMBDA -> DYNAMODB TEST ==="
echo "============================================================"

echo
echo "=== 1. VERIFY FLOCI AND CORE IDENTITY ==="

ACCOUNT_RESULT="$(
  aws_local sts get-caller-identity \
    --query Account \
    --output text
)"

assert_equals "STS_ACCOUNT" "$ACCOUNT_ID" "$ACCOUNT_RESULT"

echo
echo "=== 2. CREATE DYNAMODB TABLE ==="

if aws_local dynamodb describe-table --table-name "$TABLE_NAME" >/dev/null 2>&1; then
  echo "TABLE_STATUS=ALREADY_PRESENT"
else
  aws_local dynamodb create-table \
    --table-name "$TABLE_NAME" \
    --attribute-definitions AttributeName=order_id,AttributeType=S \
    --key-schema AttributeName=order_id,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    >/dev/null
  echo "TABLE_STATUS=CREATED"
fi

TABLE_STATE="$(
  aws_local dynamodb describe-table \
    --table-name "$TABLE_NAME" \
    --query 'Table.TableStatus' \
    --output text
)"

assert_equals "DYNAMODB_TABLE_STATE" "ACTIVE" "$TABLE_STATE"

echo
echo "=== 3. CREATE SQS QUEUE ==="

QUEUE_URL="$(
  aws_local sqs create-queue \
    --queue-name "$QUEUE_NAME" \
    --query QueueUrl \
    --output text
)"

QUEUE_ARN="$(
  aws_local sqs get-queue-attributes \
    --queue-url "$QUEUE_URL" \
    --attribute-names QueueArn \
    --query 'Attributes.QueueArn' \
    --output text
)"

EXPECTED_QUEUE_ARN="arn:aws:sqs:${REGION}:${ACCOUNT_ID}:${QUEUE_NAME}"

assert_equals "SQS_QUEUE_ARN" "$EXPECTED_QUEUE_ARN" "$QUEUE_ARN"

echo "QUEUE_URL=${QUEUE_URL}"
echo "QUEUE_ARN=${QUEUE_ARN}"

echo
echo "=== 4. CREATE LAMBDA ROLE AND INLINE POLICY ==="

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

cat >"${WORK_DIR}/role-policy.json" <<JSON
{
  "Version": "2012-10-17",
  "Statement": [
    {
      "Effect": "Allow",
      "Action": [
        "sqs:ReceiveMessage",
        "sqs:DeleteMessage",
        "sqs:GetQueueAttributes"
      ],
      "Resource": "${QUEUE_ARN}"
    },
    {
      "Effect": "Allow",
      "Action": [
        "dynamodb:PutItem",
        "dynamodb:GetItem"
      ],
      "Resource": "${TABLE_ARN}"
    }
  ]
}
JSON

aws_local iam put-role-policy \
  --role-name "$ROLE_NAME" \
  --policy-name "$POLICY_NAME" \
  --policy-document "file://${WORK_DIR}/role-policy.json"

ROLE_RESULT="$(
  aws_local iam get-role \
    --role-name "$ROLE_NAME" \
    --query 'Role.Arn' \
    --output text
)"

assert_equals "IAM_ROLE_ARN" "$ROLE_ARN" "$ROLE_RESULT"

echo
echo "=== 5. PACKAGE EVENT PROCESSOR FUNCTION ==="

cat >"${WORK_DIR}/lambda_function.py" <<'PY'
import json
import os
from typing import Any

import boto3

TABLE_NAME = os.environ["TABLE_NAME"]
FLOCI_ENDPOINT_URL = os.environ["FLOCI_ENDPOINT_URL"]

dynamodb = boto3.client(
    "dynamodb",
    endpoint_url=FLOCI_ENDPOINT_URL,
    region_name=os.environ.get("AWS_REGION", "us-east-1"),
)


def handler(event: dict[str, Any], context: Any) -> dict[str, Any]:
    processed: list[str] = []

    for record in event.get("Records", []):
        body_text = record.get("body") or record.get("Body")
        if not body_text:
            raise ValueError(f"SQS record has no body: {record}")

        body = json.loads(body_text)
        order_id = body["order_id"]
        status = body.get("status", "created")
        message_id = record.get("messageId") or record.get("MessageId") or "unknown"

        dynamodb.put_item(
            TableName=TABLE_NAME,
            Item={
                "order_id": {"S": order_id},
                "status": {"S": status},
                "source": {"S": "sqs-lambda"},
                "message_id": {"S": message_id},
                "processed_by": {
                    "S": getattr(context, "function_name", "unknown")
                },
            },
        )
        processed.append(order_id)

    return {
        "processed": processed,
        "count": len(processed),
    }
PY

(
  cd "$WORK_DIR"
  python3 -m zipfile -c function.zip lambda_function.py
)

test -s "${WORK_DIR}/function.zip"
echo "FUNCTION_PACKAGE=PASS"

echo
echo "=== 6. REMOVE PREVIOUS TEST MAPPINGS AND FUNCTION ==="

EXISTING_MAPPINGS="$(
  aws_local lambda list-event-source-mappings \
    --function-name "$FUNCTION_NAME" \
    --query 'EventSourceMappings[].UUID' \
    --output text 2>/dev/null || true
)"

for existing_uuid in $EXISTING_MAPPINGS; do
  aws_local lambda delete-event-source-mapping \
    --uuid "$existing_uuid" \
    >/dev/null
  echo "OLD_MAPPING_DELETED=${existing_uuid}"
done

if [ -n "$EXISTING_MAPPINGS" ]; then
  for attempt in $(seq 1 30); do
    REMAINING_MAPPINGS="$(
      aws_local lambda list-event-source-mappings \
        --function-name "$FUNCTION_NAME" \
        --query 'length(EventSourceMappings)' \
        --output text 2>/dev/null || echo 0
    )"

    echo "mapping_cleanup_attempt=${attempt} remaining=${REMAINING_MAPPINGS}"

    if [ "$REMAINING_MAPPINGS" = "0" ]; then
      break
    fi

    sleep 1
  done

  [ "${REMAINING_MAPPINGS:-0}" = "0" ]
fi

if aws_local lambda get-function --function-name "$FUNCTION_NAME" >/dev/null 2>&1; then
  aws_local lambda delete-function --function-name "$FUNCTION_NAME"
  echo "OLD_FUNCTION_DELETED=YES"
fi

echo
echo "=== 7. CREATE EVENT PROCESSOR FUNCTION ==="

cat >"${WORK_DIR}/environment.json" <<JSON
{
  "Variables": {
    "TABLE_NAME": "${TABLE_NAME}",
    "FLOCI_ENDPOINT_URL": "${INTERNAL_ENDPOINT}"
  }
}
JSON

aws_local lambda create-function \
  --function-name "$FUNCTION_NAME" \
  --runtime "$RUNTIME" \
  --role "$ROLE_ARN" \
  --handler "$HANDLER" \
  --zip-file "fileb://${WORK_DIR}/function.zip" \
  --environment "file://${WORK_DIR}/environment.json" \
  --timeout 30 \
  --memory-size 128 \
  >/dev/null

FUNCTION_STATE="UNKNOWN"
LAST_UPDATE="UNKNOWN"

for attempt in $(seq 1 30); do
  FUNCTION_STATE="$(
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

  echo "function_attempt=${attempt} state=${FUNCTION_STATE:-UNKNOWN} last_update=${LAST_UPDATE:-UNKNOWN}"

  if [ "$FUNCTION_STATE" = "Active" ] && {
    [ "$LAST_UPDATE" = "Successful" ] || [ "$LAST_UPDATE" = "None" ];
  }; then
    break
  fi

  sleep 1
done

assert_equals "LAMBDA_FUNCTION_STATE" "Active" "$FUNCTION_STATE"

echo
echo "=== 8. CREATE SQS EVENT-SOURCE MAPPING ==="

MAPPING_UUID="$(
  aws_local lambda create-event-source-mapping \
    --function-name "$FUNCTION_NAME" \
    --event-source-arn "$QUEUE_ARN" \
    --batch-size 1 \
    --enabled \
    --query UUID \
    --output text
)"

MAPPING_STATE="UNKNOWN"

for attempt in $(seq 1 30); do
  MAPPING_STATE="$(
    aws_local lambda get-event-source-mapping \
      --uuid "$MAPPING_UUID" \
      --query State \
      --output text 2>/dev/null || true
  )"

  echo "mapping_attempt=${attempt} state=${MAPPING_STATE:-UNKNOWN}"

  if [ "$MAPPING_STATE" = "Enabled" ]; then
    break
  fi

  sleep 1
done

assert_equals "EVENT_SOURCE_MAPPING_STATE" "Enabled" "$MAPPING_STATE"
echo "EVENT_SOURCE_MAPPING_UUID=${MAPPING_UUID}"

echo
echo "=== 9. SEND UNIQUE ORDER MESSAGE ==="

MESSAGE_BODY="$(
  python3 - "$RUN_ID" "$EXPECTED_STATUS" <<'PY'
import json
import sys

print(
    json.dumps(
        {
            "order_id": sys.argv[1],
            "status": sys.argv[2],
            "source": "floci-event-driven-test",
        },
        separators=(",", ":"),
    )
)
PY
)"

MESSAGE_ID="$(
  aws_local sqs send-message \
    --queue-url "$QUEUE_URL" \
    --message-body "$MESSAGE_BODY" \
    --query MessageId \
    --output text
)"

echo "ORDER_ID=${RUN_ID}"
echo "MESSAGE_ID=${MESSAGE_ID}"

echo
echo "=== 10. WAIT FOR DYNAMODB SIDE EFFECT ==="

ACTUAL_STATUS="None"
ACTUAL_SOURCE="None"
ACTUAL_PROCESSOR="None"
ACTUAL_MESSAGE_ID="None"

for attempt in $(seq 1 60); do
  ACTUAL_STATUS="$(
    aws_local dynamodb get-item \
      --table-name "$TABLE_NAME" \
      --key "{\"order_id\":{\"S\":\"${RUN_ID}\"}}" \
      --consistent-read \
      --query 'Item.status.S' \
      --output text 2>/dev/null || true
  )"

  echo "ddb_attempt=${attempt} status=${ACTUAL_STATUS:-None}"

  if [ "$ACTUAL_STATUS" = "$EXPECTED_STATUS" ]; then
    break
  fi

  sleep 1
 done

ACTUAL_SOURCE="$(
  aws_local dynamodb get-item \
    --table-name "$TABLE_NAME" \
    --key "{\"order_id\":{\"S\":\"${RUN_ID}\"}}" \
    --consistent-read \
    --query 'Item.source.S' \
    --output text
)"

ACTUAL_PROCESSOR="$(
  aws_local dynamodb get-item \
    --table-name "$TABLE_NAME" \
    --key "{\"order_id\":{\"S\":\"${RUN_ID}\"}}" \
    --consistent-read \
    --query 'Item.processed_by.S' \
    --output text
)"

ACTUAL_MESSAGE_ID="$(
  aws_local dynamodb get-item \
    --table-name "$TABLE_NAME" \
    --key "{\"order_id\":{\"S\":\"${RUN_ID}\"}}" \
    --consistent-read \
    --query 'Item.message_id.S' \
    --output text
)"

assert_equals "DYNAMODB_ORDER_STATUS" "$EXPECTED_STATUS" "$ACTUAL_STATUS"
assert_equals "DYNAMODB_ORDER_SOURCE" "sqs-lambda" "$ACTUAL_SOURCE"
assert_equals "DYNAMODB_ORDER_PROCESSOR" "$FUNCTION_NAME" "$ACTUAL_PROCESSOR"
assert_equals "DYNAMODB_MESSAGE_ID" "$MESSAGE_ID" "$ACTUAL_MESSAGE_ID"

echo
echo "=== 11. FINAL RESOURCE READ-BACK ==="

aws_local lambda get-event-source-mapping \
  --uuid "$MAPPING_UUID" \
  --query '{UUID:UUID,State:State,BatchSize:BatchSize,EventSourceArn:EventSourceArn,FunctionArn:FunctionArn}'

aws_local dynamodb get-item \
  --table-name "$TABLE_NAME" \
  --key "{\"order_id\":{\"S\":\"${RUN_ID}\"}}" \
  --consistent-read

sudo docker ps \
  --filter "ancestor=${RUNTIME_IMAGE}" \
  --format 'table {{.ID}}\t{{.Image}}\t{{.Names}}\t{{.Status}}\t{{.Networks}}'

echo
echo "SQS_MESSAGE_SEND_TEST=PASS"
echo "SQS_EVENT_SOURCE_MAPPING_TEST=PASS"
echo "LAMBDA_ASYNC_PROCESSING_TEST=PASS"
echo "DYNAMODB_SIDE_EFFECT_TEST=PASS"

echo
echo "============================================================"
echo "FLOCI_SQS_LAMBDA_DYNAMODB_TEST=PASS"
echo "ORDER_ID=${RUN_ID}"
echo "RESOURCES_LEFT_PRESENT=YES"
echo "============================================================"
