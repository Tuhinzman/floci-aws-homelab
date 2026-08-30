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
COMPOSE_FILE="${REPO_ROOT}/compose/compose.yaml"

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
QUEUE_NAME="${FLOCI_EVENT_QUEUE:-floci-orders-events}"
TABLE_NAME="${FLOCI_EVENT_TABLE:-FlociOrders}"
RUNTIME="${FLOCI_EVENT_RUNTIME:-python3.13}"
REGION="${FLOCI_REGION:-us-east-1}"
ACCOUNT_ID="000000000000"
RUNTIME_IMAGE="public.ecr.aws/lambda/python:${RUNTIME#python}"
EXPECTED_QUEUE_ARN="arn:aws:sqs:${REGION}:${ACCOUNT_ID}:${QUEUE_NAME}"
EXPECTED_QUEUE_URL="http://${FLOCI_INTERNAL_HOSTNAME}:4566/${ACCOUNT_ID}/${QUEUE_NAME}"
RUN_ID="restart-order-$(date -u +%Y%m%dT%H%M%SZ)-$$"
EXPECTED_STATUS="created"
QUEUE_URL=""
QUEUE_ARN=""
MAPPING_UUID_BEFORE=""
MESSAGE_ID=""

compose() {
  sudo docker compose \
    --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" \
    "$@"
}

aws_local() {
  aws-floci \
    --cli-connect-timeout 10 \
    --cli-read-timeout 300 \
    "$@"
}

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

diagnostics() {
  local exit_code=$?
  set +e

  echo
  echo "============================================================"
  echo "=== EVENT-DRIVEN PERSISTENCE DIAGNOSTICS ==="
  echo "============================================================"

  compose ps

  aws_local lambda list-event-source-mappings \
    --function-name "$FUNCTION_NAME"

  aws_local lambda get-function-configuration \
    --function-name "$FUNCTION_NAME"

  aws_local dynamodb describe-table \
    --table-name "$TABLE_NAME"

  if [ -n "$QUEUE_URL" ]; then
    aws_local sqs get-queue-attributes \
      --queue-url "$QUEUE_URL" \
      --attribute-names All
  fi

  sudo docker ps \
    --format 'table {{.ID}}\t{{.Image}}\t{{.Names}}\t{{.Status}}\t{{.Networks}}'

  sudo docker logs --since 5m floci 2>&1 | tail -200

  echo "FLOCI_EVENT_DRIVEN_PERSISTENCE_TEST=FAIL"
  exit "$exit_code"
}

trap diagnostics ERR

echo "============================================================"
echo "=== FLOCI EVENT-DRIVEN PERSISTENCE TEST ==="
echo "============================================================"

echo
echo "=== 1. READ RESOURCES BEFORE RESTART ==="

QUEUE_URL="$(
  aws_local sqs get-queue-url \
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

TABLE_STATE_BEFORE="$(
  aws_local dynamodb describe-table \
    --table-name "$TABLE_NAME" \
    --query 'Table.TableStatus' \
    --output text
)"

FUNCTION_STATE_BEFORE="$(
  aws_local lambda get-function-configuration \
    --function-name "$FUNCTION_NAME" \
    --query State \
    --output text
)"

MAPPING_UUID_BEFORE="$(
  aws_local lambda list-event-source-mappings \
    --function-name "$FUNCTION_NAME" \
    --event-source-arn "$QUEUE_ARN" \
    --query 'EventSourceMappings[0].UUID' \
    --output text
)"

if [ "$MAPPING_UUID_BEFORE" = "None" ] || [ -z "$MAPPING_UUID_BEFORE" ]; then
  echo "No event-source mapping was found before restart."
  exit 1
fi

MAPPING_STATE_BEFORE="$(
  aws_local lambda get-event-source-mapping \
    --uuid "$MAPPING_UUID_BEFORE" \
    --query State \
    --output text
)"

echo "QUEUE_URL_BEFORE=${QUEUE_URL}"
echo "QUEUE_ARN_BEFORE=${QUEUE_ARN}"
echo "TABLE_STATE_BEFORE=${TABLE_STATE_BEFORE}"
echo "FUNCTION_STATE_BEFORE=${FUNCTION_STATE_BEFORE}"
echo "MAPPING_UUID_BEFORE=${MAPPING_UUID_BEFORE}"
echo "MAPPING_STATE_BEFORE=${MAPPING_STATE_BEFORE}"

assert_equals "QUEUE_URL_BEFORE_RESTART" "$EXPECTED_QUEUE_URL" "$QUEUE_URL"
assert_equals "QUEUE_ARN_BEFORE_RESTART" "$EXPECTED_QUEUE_ARN" "$QUEUE_ARN"
assert_equals "TABLE_STATE_BEFORE_RESTART" "ACTIVE" "$TABLE_STATE_BEFORE"
assert_equals "FUNCTION_STATE_BEFORE_RESTART" "Active" "$FUNCTION_STATE_BEFORE"
assert_equals "MAPPING_STATE_BEFORE_RESTART" "Enabled" "$MAPPING_STATE_BEFORE"

echo
echo "=== 2. RESTART FLOCI ==="

compose restart floci

HEALTH="none"
for attempt in $(seq 1 30); do
  HEALTH="$(
    sudo docker inspect floci \
      --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}'
  )"

  echo "health_attempt=${attempt} health=${HEALTH}"

  if [ "$HEALTH" = "healthy" ]; then
    break
  fi

  sleep 1
done

assert_equals "FLOCI_HEALTH_AFTER_RESTART" "healthy" "$HEALTH"

echo
echo "=== 3. READ RESOURCES AFTER RESTART ==="

QUEUE_URL_AFTER="$(
  aws_local sqs get-queue-url \
    --queue-name "$QUEUE_NAME" \
    --query QueueUrl \
    --output text
)"

QUEUE_ARN_AFTER="$(
  aws_local sqs get-queue-attributes \
    --queue-url "$QUEUE_URL_AFTER" \
    --attribute-names QueueArn \
    --query 'Attributes.QueueArn' \
    --output text
)"

TABLE_STATE_AFTER="$(
  aws_local dynamodb describe-table \
    --table-name "$TABLE_NAME" \
    --query 'Table.TableStatus' \
    --output text
)"

FUNCTION_STATE_AFTER="$(
  aws_local lambda get-function-configuration \
    --function-name "$FUNCTION_NAME" \
    --query State \
    --output text
)"

MAPPING_UUID_AFTER="$(
  aws_local lambda list-event-source-mappings \
    --function-name "$FUNCTION_NAME" \
    --event-source-arn "$QUEUE_ARN_AFTER" \
    --query 'EventSourceMappings[0].UUID' \
    --output text
)"

if [ "$MAPPING_UUID_AFTER" = "None" ] || [ -z "$MAPPING_UUID_AFTER" ]; then
  echo "No event-source mapping was found after restart."
  exit 1
fi

MAPPING_STATE_AFTER="$(
  aws_local lambda get-event-source-mapping \
    --uuid "$MAPPING_UUID_AFTER" \
    --query State \
    --output text
)"

echo "QUEUE_URL_AFTER=${QUEUE_URL_AFTER}"
echo "QUEUE_ARN_AFTER=${QUEUE_ARN_AFTER}"
echo "TABLE_STATE_AFTER=${TABLE_STATE_AFTER}"
echo "FUNCTION_STATE_AFTER=${FUNCTION_STATE_AFTER}"
echo "MAPPING_UUID_AFTER=${MAPPING_UUID_AFTER}"
echo "MAPPING_STATE_AFTER=${MAPPING_STATE_AFTER}"

assert_equals "QUEUE_URL_PERSISTENCE" "$QUEUE_URL" "$QUEUE_URL_AFTER"
assert_equals "QUEUE_ARN_PERSISTENCE" "$QUEUE_ARN" "$QUEUE_ARN_AFTER"
assert_equals "DYNAMODB_TABLE_PERSISTENCE" "ACTIVE" "$TABLE_STATE_AFTER"
assert_equals "LAMBDA_FUNCTION_PERSISTENCE" "Active" "$FUNCTION_STATE_AFTER"
assert_equals "EVENT_SOURCE_MAPPING_UUID_PERSISTENCE" "$MAPPING_UUID_BEFORE" "$MAPPING_UUID_AFTER"
assert_equals "EVENT_SOURCE_MAPPING_STATE_PERSISTENCE" "Enabled" "$MAPPING_STATE_AFTER"

echo
echo "=== 4. SEND A NEW MESSAGE AFTER RESTART ==="

MESSAGE_ID="$(
  aws_local sqs send-message \
    --queue-url "$QUEUE_URL_AFTER" \
    --message-body "{\"order_id\":\"${RUN_ID}\",\"status\":\"${EXPECTED_STATUS}\"}" \
    --query MessageId \
    --output text
)"

echo "ORDER_ID=${RUN_ID}"
echo "MESSAGE_ID=${MESSAGE_ID}"

if [ -z "$MESSAGE_ID" ] || [ "$MESSAGE_ID" = "None" ]; then
  echo "SQS did not return a message ID."
  exit 1
fi

echo "SQS_MESSAGE_AFTER_RESTART=PASS"

echo
echo "=== 5. WAIT FOR NEW DYNAMODB ITEM ==="

ORDER_STATUS="None"
for attempt in $(seq 1 60); do
  ORDER_STATUS="$(
    aws_local dynamodb get-item \
      --table-name "$TABLE_NAME" \
      --key "{\"order_id\":{\"S\":\"${RUN_ID}\"}}" \
      --query 'Item.status.S' \
      --output text 2>/dev/null || true
  )"

  echo "ddb_attempt=${attempt} status=${ORDER_STATUS:-None}"

  if [ "$ORDER_STATUS" = "$EXPECTED_STATUS" ]; then
    break
  fi

  sleep 1
done

ORDER_SOURCE="$(
  aws_local dynamodb get-item \
    --table-name "$TABLE_NAME" \
    --key "{\"order_id\":{\"S\":\"${RUN_ID}\"}}" \
    --query 'Item.source.S' \
    --output text
)"

ORDER_PROCESSOR="$(
  aws_local dynamodb get-item \
    --table-name "$TABLE_NAME" \
    --key "{\"order_id\":{\"S\":\"${RUN_ID}\"}}" \
    --query 'Item.processed_by.S' \
    --output text
)"

ORDER_MESSAGE_ID="$(
  aws_local dynamodb get-item \
    --table-name "$TABLE_NAME" \
    --key "{\"order_id\":{\"S\":\"${RUN_ID}\"}}" \
    --query 'Item.message_id.S' \
    --output text
)"

assert_equals "DYNAMODB_ORDER_STATUS_AFTER_RESTART" "$EXPECTED_STATUS" "$ORDER_STATUS"
assert_equals "DYNAMODB_ORDER_SOURCE_AFTER_RESTART" "sqs-lambda" "$ORDER_SOURCE"
assert_equals "DYNAMODB_ORDER_PROCESSOR_AFTER_RESTART" "$FUNCTION_NAME" "$ORDER_PROCESSOR"
assert_equals "DYNAMODB_MESSAGE_ID_AFTER_RESTART" "$MESSAGE_ID" "$ORDER_MESSAGE_ID"

echo
echo "=== 6. VERIFY DOCKER-BACKED EXECUTION AFTER RESTART ==="

LAMBDA_CONTAINER_ID="$(
  sudo docker ps \
    --filter "ancestor=${RUNTIME_IMAGE}" \
    --format '{{.ID}} {{.Names}}' \
    | awk -v function_name="$FUNCTION_NAME" '$2 ~ function_name {print $1; exit}'
)"

if [ -z "$LAMBDA_CONTAINER_ID" ]; then
  echo "No running Lambda container was found for ${FUNCTION_NAME}."
  exit 1
fi

LAMBDA_CONTAINER_STATUS="$(
  sudo docker inspect "$LAMBDA_CONTAINER_ID" \
    --format '{{.State.Status}}'
)"

LAMBDA_CONTAINER_NETWORKS="$(
  sudo docker inspect "$LAMBDA_CONTAINER_ID" \
    --format '{{range $name, $_ := .NetworkSettings.Networks}}{{$name}} {{end}}'
)"

assert_equals "LAMBDA_CONTAINER_STATUS_AFTER_RESTART" "running" "$LAMBDA_CONTAINER_STATUS"

case " ${LAMBDA_CONTAINER_NETWORKS} " in
  *" floci_default "*)
    echo "LAMBDA_CONTAINER_NETWORK_AFTER_RESTART=PASS"
    ;;
  *)
    echo "LAMBDA_CONTAINER_NETWORK_AFTER_RESTART=FAIL" >&2
    echo "Actual networks: ${LAMBDA_CONTAINER_NETWORKS}" >&2
    exit 1
    ;;
esac

echo
echo "=== 7. FINAL ITEM READ-BACK ==="

aws_local dynamodb get-item \
  --table-name "$TABLE_NAME" \
  --key "{\"order_id\":{\"S\":\"${RUN_ID}\"}}"

echo
echo "SQS_RESOURCE_PERSISTENCE=PASS"
echo "DYNAMODB_RESOURCE_PERSISTENCE=PASS"
echo "LAMBDA_FUNCTION_PERSISTENCE=PASS"
echo "EVENT_SOURCE_MAPPING_PERSISTENCE=PASS"
echo "EVENT_DRIVEN_PROCESSING_AFTER_RESTART=PASS"

echo
echo "============================================================"
echo "FLOCI_EVENT_DRIVEN_PERSISTENCE_TEST=PASS"
echo "ORDER_ID=${RUN_ID}"
echo "RESOURCES_LEFT_PRESENT=YES"
echo "============================================================"
