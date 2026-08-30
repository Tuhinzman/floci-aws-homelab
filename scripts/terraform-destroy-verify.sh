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

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
STACK_DIR="${REPO_ROOT}/terraform/event-driven"
PLAN_FILE="${STACK_DIR}/terraform-destroy.tfplan"
PLAN_JSON="${STACK_DIR}/terraform-destroy.tfplan.json"

export TF_IN_AUTOMATION=1

aws_local() {
  aws-floci \
    --cli-connect-timeout 10 \
    --cli-read-timeout 300 \
    "$@"
}

assert_absent() {
  local label="$1"
  shift

  if "$@" >/dev/null 2>&1; then
    echo "${label}=FAIL" >&2
    echo "The resource is still reachable." >&2
    exit 1
  fi

  echo "${label}=PASS"
}

diagnostics() {
  local exit_code=$?
  set +e

  echo
  echo "============================================================"
  echo "=== TERRAFORM DESTROY DIAGNOSTICS ==="
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

  echo "FLOCI_TERRAFORM_DESTROY_VALIDATION=FAIL"
  exit "$exit_code"
}

trap diagnostics ERR

echo "============================================================"
echo "=== FLOCI TERRAFORM DESTROY AND CLEANUP VALIDATION ==="
echo "============================================================"

echo
echo "=== 1. VERIFY TERRAFORM-MANAGED STATE ==="

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

ACTUAL_MANAGED_STATE="$(
  terraform -chdir="$STACK_DIR" state list |
    awk '!/^data\./' |
    sort
)"

DATA_STATE_BEFORE_DESTROY="$(
  terraform -chdir="$STACK_DIR" state list |
    awk '/^data\./' |
    sort
)"

if [ "$ACTUAL_MANAGED_STATE" != "$EXPECTED_MANAGED_STATE" ]; then
  echo "Terraform managed state does not contain the expected six resources."
  echo "Expected managed resources:"
  printf '%s\n' "$EXPECTED_MANAGED_STATE"
  echo "Actual managed resources:"
  printf '%s\n' "$ACTUAL_MANAGED_STATE"
  exit 1
fi

echo "TERRAFORM_MANAGED_STATE_PRE_DESTROY=PASS"
echo "TERRAFORM_DATA_STATE_BEFORE_DESTROY_BEGIN"
printf '%s\n' "$DATA_STATE_BEFORE_DESTROY"
echo "TERRAFORM_DATA_STATE_BEFORE_DESTROY_END"

QUEUE_NAME="$(terraform -chdir="$STACK_DIR" output -raw queue_name)"
TABLE_NAME="$(terraform -chdir="$STACK_DIR" output -raw dynamodb_table_name)"
FUNCTION_NAME="$(terraform -chdir="$STACK_DIR" output -raw lambda_function_name)"
ROLE_NAME="$(terraform -chdir="$STACK_DIR" output -raw iam_role_name)"
MAPPING_UUID="$(terraform -chdir="$STACK_DIR" output -raw event_source_mapping_uuid)"

echo "QUEUE_NAME=${QUEUE_NAME}"
echo "TABLE_NAME=${TABLE_NAME}"
echo "FUNCTION_NAME=${FUNCTION_NAME}"
echo "ROLE_NAME=${ROLE_NAME}"
echo "MAPPING_UUID=${MAPPING_UUID}"

echo
echo "=== 2. CREATE AND ASSERT DESTROY PLAN ==="

terraform -chdir="$STACK_DIR" plan \
  -destroy \
  -input=false \
  -out="$PLAN_FILE"

terraform -chdir="$STACK_DIR" show \
  -json \
  "$PLAN_FILE" \
  >"$PLAN_JSON"

python3 - "$PLAN_JSON" <<'PY'
import json
import sys
from pathlib import Path

plan = json.loads(Path(sys.argv[1]).read_text())

expected = {
    "aws_dynamodb_table.orders",
    "aws_iam_role.lambda",
    "aws_iam_role_policy.lambda",
    "aws_lambda_event_source_mapping.orders",
    "aws_lambda_function.orders",
    "aws_sqs_queue.orders",
}

deletes = set()
unexpected = []

for change in plan.get("resource_changes", []):
    if change.get("mode") != "managed":
        continue

    actions = change.get("change", {}).get("actions", [])

    if actions == ["delete"]:
        deletes.add(change["address"])
    elif actions == ["no-op"]:
        continue
    else:
        unexpected.append((change["address"], actions))

if unexpected:
    raise SystemExit(f"Unexpected managed actions: {unexpected}")

if deletes != expected:
    raise SystemExit(
        "Destroy set mismatch.\n"
        f"Expected: {sorted(expected)}\n"
        f"Actual:   {sorted(deletes)}"
    )

print("TERRAFORM_DESTROY_PLAN_EXACT_MATCH=PASS")
print(f"TERRAFORM_DESTROY_COUNT={len(deletes)}")
PY

echo
echo "=== 3. APPLY SAVED DESTROY PLAN ==="

terraform -chdir="$STACK_DIR" apply \
  -input=false \
  "$PLAN_FILE"

echo "TERRAFORM_DESTROY=PASS"

echo
echo "=== 4. VERIFY NO MANAGED RESOURCES REMAIN IN STATE ==="

REMAINING_MANAGED_STATE="$(
  terraform -chdir="$STACK_DIR" state list |
    awk '!/^data\./'
)"

DATA_STATE_AFTER_DESTROY="$(
  terraform -chdir="$STACK_DIR" state list |
    awk '/^data\./' |
    sort
)"

if [ -n "$REMAINING_MANAGED_STATE" ]; then
  echo "Terraform managed state is not empty:"
  printf '%s\n' "$REMAINING_MANAGED_STATE"
  exit 1
fi

echo "TERRAFORM_MANAGED_STATE_EMPTY=PASS"
echo "TERRAFORM_DATA_STATE_AFTER_DESTROY_BEGIN"
printf '%s\n' "$DATA_STATE_AFTER_DESTROY"
echo "TERRAFORM_DATA_STATE_AFTER_DESTROY_END"

echo
echo "=== 5. VERIFY API RESOURCES ARE ABSENT ==="

assert_absent \
  "SQS_QUEUE_ABSENT" \
  aws_local sqs get-queue-url \
  --queue-name "$QUEUE_NAME"

assert_absent \
  "DYNAMODB_TABLE_ABSENT" \
  aws_local dynamodb describe-table \
  --table-name "$TABLE_NAME"

assert_absent \
  "LAMBDA_FUNCTION_ABSENT" \
  aws_local lambda get-function \
  --function-name "$FUNCTION_NAME"

assert_absent \
  "IAM_ROLE_ABSENT" \
  aws_local iam get-role \
  --role-name "$ROLE_NAME"

MAPPING_COUNT="$(
  aws_local lambda list-event-source-mappings \
    --function-name "$FUNCTION_NAME" \
    --query 'length(EventSourceMappings)' \
    --output text 2>/dev/null || echo 0
)"

if [ "$MAPPING_COUNT" != "0" ]; then
  echo "EVENT_SOURCE_MAPPING_ABSENT=FAIL"
  echo "Remaining mapping count: ${MAPPING_COUNT}"
  exit 1
fi

echo "EVENT_SOURCE_MAPPING_ABSENT=PASS"

echo
echo "=== 6. VERIFY LAMBDA RUNTIME CONTAINER CLEANUP ==="

CONTAINER_REMAINING="YES"

for attempt in $(seq 1 30); do
  if sudo docker ps \
    --format '{{.Names}}' |
    grep -q "$FUNCTION_NAME"; then
    echo "container_cleanup_attempt=${attempt} remaining=YES"
    sleep 1
  else
    CONTAINER_REMAINING="NO"
    break
  fi
done

if [ "$CONTAINER_REMAINING" != "NO" ]; then
  echo "LAMBDA_RUNTIME_CONTAINER_ABSENT=FAIL"
  exit 1
fi

echo "LAMBDA_RUNTIME_CONTAINER_ABSENT=PASS"

echo
echo "============================================================"
echo "FLOCI_TERRAFORM_DESTROY_VALIDATION=PASS"
echo "TERRAFORM_MANAGED_RESOURCES_PRESENT=NO"
echo "============================================================"
