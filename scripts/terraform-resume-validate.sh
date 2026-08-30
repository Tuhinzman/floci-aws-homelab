#!/usr/bin/env bash
set -euo pipefail

if [ "${EUID}" -eq 0 ]; then
  echo "Run this script as your normal Linux user, not with sudo."
  exit 1
fi

for required_command in terraform aws-floci python3 sudo; do
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
STACK_DIR="${REPO_ROOT}/terraform/event-driven"
TFVARS_FILE="${STACK_DIR}/terraform.tfvars"
CONVERGENCE_LOG="${STACK_DIR}/terraform-resume-convergence.log"

if [ ! -f "$ENV_FILE" ]; then
  echo "Missing ${ENV_FILE}. Copy .env.example to .env and configure it first."
  exit 1
fi

set -a
# shellcheck disable=SC1090
. "$ENV_FILE"
set +a

: "${FLOCI_HOST_IP:?FLOCI_HOST_IP is required in .env}"
: "${FLOCI_INTERNAL_HOSTNAME:?FLOCI_INTERNAL_HOSTNAME is required in .env}"

export TF_IN_AUTOMATION=1

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
    exit 1
  fi

  echo "${label}=PASS"
}

diagnostics() {
  local exit_code=$?
  set +e

  echo
  echo "============================================================"
  echo "=== TERRAFORM RESUME VALIDATION DIAGNOSTICS ==="
  echo "============================================================"

  terraform -chdir="$STACK_DIR" state list
  terraform -chdir="$STACK_DIR" show -no-color

  aws_local lambda list-functions
  aws_local lambda list-event-source-mappings
  aws_local sqs list-queues
  aws_local dynamodb list-tables

  sudo docker ps \
    --format 'table {{.ID}}\t{{.Image}}\t{{.Names}}\t{{.Status}}\t{{.Networks}}'

  sudo docker logs --since 5m floci 2>&1 | tail -200

  echo "FLOCI_TERRAFORM_RESUME_VALIDATION=FAIL"
  exit "$exit_code"
}

trap diagnostics ERR

echo "============================================================"
echo "=== FLOCI TERRAFORM POST-APPLY RESUME VALIDATION ==="
echo "============================================================"

echo
echo "=== 1. RECREATE LOCAL TERRAFORM VARIABLES ==="

cat >"$TFVARS_FILE" <<EOF_TFVARS
floci_host_ip           = "${FLOCI_HOST_IP}"
floci_internal_hostname = "${FLOCI_INTERNAL_HOSTNAME}"
aws_region              = "${FLOCI_REGION:-us-east-1}"
EOF_TFVARS

terraform -chdir="$STACK_DIR" fmt terraform.tfvars

echo "TFVARS_FILE=${TFVARS_FILE}"
cat "$TFVARS_FILE"

echo
echo "=== 2. VERIFY TERRAFORM AND FLOCI ==="

terraform version

ACCOUNT_ID="$(
  aws_local sts get-caller-identity \
    --query Account \
    --output text
)"

assert_equals "STS_ACCOUNT" "000000000000" "$ACCOUNT_ID"

FLOCI_HEALTH="$(
  sudo docker inspect floci \
    --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}'
)"

assert_equals "FLOCI_HEALTH" "healthy" "$FLOCI_HEALTH"

echo
echo "=== 3. INITIALIZE AND VALIDATE CONFIGURATION ==="

terraform -chdir="$STACK_DIR" fmt -check -recursive
terraform -chdir="$STACK_DIR" init -input=false
terraform -chdir="$STACK_DIR" validate

echo "TERRAFORM_STATIC_VALIDATION=PASS"

echo
echo "=== 4. VERIFY MANAGED AND DATA STATE SEPARATELY ==="

EXPECTED_MANAGED_STATE="$(
  cat <<'EOF_STATE'
aws_dynamodb_table.orders
aws_iam_role.lambda
aws_iam_role_policy.lambda
aws_lambda_event_source_mapping.orders
aws_lambda_function.orders
aws_sqs_queue.orders
EOF_STATE
)"

EXPECTED_DATA_STATE="$(
  cat <<'EOF_STATE'
data.archive_file.lambda
data.aws_iam_policy_document.lambda_assume_role
data.aws_iam_policy_document.lambda_permissions
EOF_STATE
)"

ALL_STATE="$(terraform -chdir="$STACK_DIR" state list)"

ACTUAL_MANAGED_STATE="$(
  printf '%s\n' "$ALL_STATE" |
    awk '!/^data\./' |
    sort
)"

ACTUAL_DATA_STATE="$(
  printf '%s\n' "$ALL_STATE" |
    awk '/^data\./' |
    sort
)"

assert_equals \
  "TERRAFORM_MANAGED_STATE_EXACT_MATCH" \
  "$EXPECTED_MANAGED_STATE" \
  "$ACTUAL_MANAGED_STATE"

assert_equals \
  "TERRAFORM_DATA_STATE_EXACT_MATCH" \
  "$EXPECTED_DATA_STATE" \
  "$ACTUAL_DATA_STATE"

echo
echo "=== 5. VERIFY NO-CHANGE CONVERGENCE ==="

set +e
terraform -chdir="$STACK_DIR" plan \
  -detailed-exitcode \
  -input=false \
  -no-color \
  >"$CONVERGENCE_LOG" 2>&1
CONVERGENCE_RC=$?
set -e

cat "$CONVERGENCE_LOG"

if [ "$CONVERGENCE_RC" -ne 0 ]; then
  echo "Expected a no-change Terraform plan, got exit code ${CONVERGENCE_RC}."
  exit 1
fi

echo "TERRAFORM_CONVERGENCE=PASS"

echo
echo "=== 6. READ TERRAFORM OUTPUTS ==="

QUEUE_URL="$(terraform -chdir="$STACK_DIR" output -raw queue_url)"
QUEUE_ARN="$(terraform -chdir="$STACK_DIR" output -raw queue_arn)"
TABLE_NAME="$(terraform -chdir="$STACK_DIR" output -raw dynamodb_table_name)"
FUNCTION_NAME="$(terraform -chdir="$STACK_DIR" output -raw lambda_function_name)"
MAPPING_UUID="$(terraform -chdir="$STACK_DIR" output -raw event_source_mapping_uuid)"
RUNTIME_IMAGE="$(terraform -chdir="$STACK_DIR" output -raw lambda_runtime_image)"

echo "QUEUE_URL=${QUEUE_URL}"
echo "QUEUE_ARN=${QUEUE_ARN}"
echo "TABLE_NAME=${TABLE_NAME}"
echo "FUNCTION_NAME=${FUNCTION_NAME}"
echo "MAPPING_UUID=${MAPPING_UUID}"
echo "RUNTIME_IMAGE=${RUNTIME_IMAGE}"

echo
echo "=== 7. VERIFY FUNCTION AND EVENT-SOURCE MAPPING ==="

FUNCTION_STATE="$(
  aws_local lambda get-function-configuration \
    --function-name "$FUNCTION_NAME" \
    --query State \
    --output text
)"

MAPPING_STATE="$(
  aws_local lambda get-event-source-mapping \
    --uuid "$MAPPING_UUID" \
    --query State \
    --output text
)"

assert_equals "LAMBDA_FUNCTION_STATE" "Active" "$FUNCTION_STATE"
assert_equals "EVENT_SOURCE_MAPPING_STATE" "Enabled" "$MAPPING_STATE"

echo
echo "=== 8. SEND UNIQUE SQS MESSAGE ==="

ORDER_ID="tf-resume-order-$(date -u +%Y%m%dT%H%M%SZ)-$$"
EXPECTED_STATUS="created"

MESSAGE_ID="$(
  aws_local sqs send-message \
    --queue-url "$QUEUE_URL" \
    --message-body "{\"order_id\":\"${ORDER_ID}\",\"status\":\"${EXPECTED_STATUS}\"}" \
    --query MessageId \
    --output text
)"

if [ -z "$MESSAGE_ID" ] || [ "$MESSAGE_ID" = "None" ]; then
  echo "SQS did not return a message ID."
  exit 1
fi

echo "ORDER_ID=${ORDER_ID}"
echo "MESSAGE_ID=${MESSAGE_ID}"
echo "SQS_MESSAGE_SEND=PASS"

echo
echo "=== 9. WAIT FOR DYNAMODB SIDE EFFECT ==="

ORDER_STATUS="None"

for attempt in $(seq 1 60); do
  ORDER_STATUS="$(
    aws_local dynamodb get-item \
      --table-name "$TABLE_NAME" \
      --key "{\"order_id\":{\"S\":\"${ORDER_ID}\"}}" \
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
    --key "{\"order_id\":{\"S\":\"${ORDER_ID}\"}}" \
    --query 'Item.source.S' \
    --output text
)"

ORDER_PROCESSOR="$(
  aws_local dynamodb get-item \
    --table-name "$TABLE_NAME" \
    --key "{\"order_id\":{\"S\":\"${ORDER_ID}\"}}" \
    --query 'Item.processed_by.S' \
    --output text
)"

ORDER_MESSAGE_ID="$(
  aws_local dynamodb get-item \
    --table-name "$TABLE_NAME" \
    --key "{\"order_id\":{\"S\":\"${ORDER_ID}\"}}" \
    --query 'Item.message_id.S' \
    --output text
)"

assert_equals "DYNAMODB_ORDER_STATUS" "$EXPECTED_STATUS" "$ORDER_STATUS"
assert_equals "DYNAMODB_ORDER_SOURCE" "terraform-sqs-lambda" "$ORDER_SOURCE"
assert_equals "DYNAMODB_ORDER_PROCESSOR" "$FUNCTION_NAME" "$ORDER_PROCESSOR"
assert_equals "DYNAMODB_MESSAGE_ID" "$MESSAGE_ID" "$ORDER_MESSAGE_ID"

echo
echo "=== 10. VERIFY DOCKER-BACKED LAMBDA EXECUTION ==="

LAMBDA_CONTAINER_ID="$(
  sudo docker ps \
    --filter "ancestor=${RUNTIME_IMAGE}" \
    --format '{{.ID}} {{.Names}}' |
    awk -v function_name="$FUNCTION_NAME" '$2 ~ function_name {print $1; exit}'
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

assert_equals \
  "LAMBDA_CONTAINER_STATUS" \
  "running" \
  "$LAMBDA_CONTAINER_STATUS"

case " ${LAMBDA_CONTAINER_NETWORKS} " in
  *" floci_default "*)
    echo "LAMBDA_CONTAINER_NETWORK=PASS"
    ;;
  *)
    echo "LAMBDA_CONTAINER_NETWORK=FAIL" >&2
    echo "Actual networks: ${LAMBDA_CONTAINER_NETWORKS}" >&2
    exit 1
    ;;
esac

echo
echo "=== 11. FINAL RESOURCE READ-BACK ==="

aws_local lambda get-event-source-mapping \
  --uuid "$MAPPING_UUID"

aws_local dynamodb get-item \
  --table-name "$TABLE_NAME" \
  --key "{\"order_id\":{\"S\":\"${ORDER_ID}\"}}"

echo
echo "TERRAFORM_RESUME_STATE_VALIDATION=PASS"
echo "TERRAFORM_CONVERGENCE=PASS"
echo "TERRAFORM_EVENT_DRIVEN_FUNCTIONAL_TEST=PASS"
echo "TERRAFORM_RESOURCES_LEFT_PRESENT=YES"

echo
echo "============================================================"
echo "FLOCI_TERRAFORM_RESUME_VALIDATION=PASS"
echo "ORDER_ID=${ORDER_ID}"
echo "============================================================"
