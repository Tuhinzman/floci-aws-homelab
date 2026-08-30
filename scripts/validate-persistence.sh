#!/usr/bin/env bash
set -euo pipefail

if [ "${EUID}" -eq 0 ]; then
  echo "Run this script as your normal Linux user, not with sudo."
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

: "${FLOCI_HOST_IP:?FLOCI_HOST_IP is required in .env}"

FLOCI_INTERNAL_HOSTNAME="${FLOCI_INTERNAL_HOSTNAME:-floci}"
BUCKET="${FLOCI_TEST_BUCKET:-floci-test-bucket}"
QUEUE="${FLOCI_TEST_QUEUE:-floci-test-orders}"
TABLE="${FLOCI_TEST_TABLE:-FlociTestUsers}"
PARAM="${FLOCI_TEST_PARAM:-/floci/test/environment}"
SECRET="${FLOCI_TEST_SECRET:-floci/test/database}"

compose() {
  sudo docker compose \
    --env-file "$ENV_FILE" \
    -f "$COMPOSE_FILE" \
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

echo "Restarting Floci..."
compose restart floci

HEALTH="none"
for attempt in $(seq 1 30); do
  HEALTH="$(sudo docker inspect floci --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}')"
  echo "attempt=${attempt} health=${HEALTH}"

  if [ "$HEALTH" = "healthy" ]; then
    break
  fi

  sleep 1
done

if [ "$HEALTH" != "healthy" ]; then
  echo "Floci did not become healthy after restart."
  compose logs --tail=100 floci
  exit 1
fi

echo "Reading persisted resources..."

S3_OBJECT="$(aws-floci s3 cp "s3://${BUCKET}/hello.txt" -)"
QUEUE_URL="$(aws-floci sqs get-queue-url --queue-name "$QUEUE" --query QueueUrl --output text)"
DDB_NAME="$(aws-floci dynamodb get-item --table-name "$TABLE" --key '{"id":{"S":"user-001"}}' --query 'Item.name.S' --output text)"
SSM_VALUE="$(aws-floci ssm get-parameter --name "$PARAM" --query 'Parameter.Value' --output text)"
SECRET_NAME="$(aws-floci secretsmanager describe-secret --secret-id "$SECRET" --query Name --output text)"
EXPECTED_QUEUE_URL="http://${FLOCI_INTERNAL_HOSTNAME}:4566/000000000000/${QUEUE}"

echo "S3_OBJECT=${S3_OBJECT}"
echo "QUEUE_URL=${QUEUE_URL}"
echo "DYNAMODB_NAME=${DDB_NAME}"
echo "SSM_VALUE=${SSM_VALUE}"
echo "SECRET_NAME=${SECRET_NAME}"

assert_equals "S3_PERSISTENCE" "hello from floci" "$S3_OBJECT"
assert_equals "SQS_PERSISTENCE" "$EXPECTED_QUEUE_URL" "$QUEUE_URL"
assert_equals "DYNAMODB_PERSISTENCE" "Tuhin" "$DDB_NAME"
assert_equals "SSM_PERSISTENCE" "development" "$SSM_VALUE"
assert_equals "SECRETS_MANAGER_PERSISTENCE" "$SECRET" "$SECRET_NAME"

echo "FLOCI_PERSISTENCE_VALIDATION=PASS"
