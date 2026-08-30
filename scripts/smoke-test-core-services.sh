#!/usr/bin/env bash
set -euo pipefail

if [ "${EUID}" -eq 0 ]; then
  echo "Run this script as your normal Linux user, not with sudo."
  exit 1
fi

if ! command -v aws-floci >/dev/null 2>&1; then
  echo "aws-floci was not found. Run scripts/configure-floci-cli.sh first."
  exit 1
fi

BUCKET="${FLOCI_TEST_BUCKET:-floci-test-bucket}"
QUEUE="${FLOCI_TEST_QUEUE:-floci-test-orders}"
TABLE="${FLOCI_TEST_TABLE:-FlociTestUsers}"
PARAM="${FLOCI_TEST_PARAM:-/floci/test/environment}"
SECRET="${FLOCI_TEST_SECRET:-floci/test/database}"
EXPECTED_MESSAGE='{"order_id":"12345","status":"created"}'
EXPECTED_SECRET='{"username":"flociuser","password":"test-only-password"}'
TMP_FILE="$(mktemp)"
trap 'rm -f "$TMP_FILE"' EXIT

echo "=== STS ==="
ACCOUNT="$(aws-floci sts get-caller-identity --query Account --output text)"
[ "$ACCOUNT" = "000000000000" ]
echo "STS_TEST=PASS"

echo "=== S3 ==="
if ! aws-floci s3api head-bucket --bucket "$BUCKET" >/dev/null 2>&1; then
  aws-floci s3 mb "s3://${BUCKET}" >/dev/null
fi

printf '%s\n' "hello from floci" >"$TMP_FILE"
aws-floci s3 cp "$TMP_FILE" "s3://${BUCKET}/hello.txt" >/dev/null
S3_OBJECT="$(aws-floci s3 cp "s3://${BUCKET}/hello.txt" -)"
[ "$S3_OBJECT" = "hello from floci" ]
echo "S3_TEST=PASS"

echo "=== SQS ==="
QUEUE_URL="$(aws-floci sqs create-queue --queue-name "$QUEUE" --query QueueUrl --output text)"
aws-floci sqs send-message \
  --queue-url "$QUEUE_URL" \
  --message-body "$EXPECTED_MESSAGE" \
  >/dev/null

SQS_BODY="None"
for attempt in $(seq 1 10); do
  SQS_BODY="$(
    aws-floci sqs receive-message \
      --queue-url "$QUEUE_URL" \
      --max-number-of-messages 1 \
      --query 'Messages[0].Body' \
      --output text
  )"

  if [ "$SQS_BODY" != "None" ]; then
    break
  fi

  echo "attempt=${attempt} message=not-yet-visible"
  sleep 1
done

[ "$SQS_BODY" = "$EXPECTED_MESSAGE" ]
echo "SQS_TEST=PASS"

echo "=== DynamoDB ==="
if ! aws-floci dynamodb describe-table --table-name "$TABLE" >/dev/null 2>&1; then
  aws-floci dynamodb create-table \
    --table-name "$TABLE" \
    --attribute-definitions AttributeName=id,AttributeType=S \
    --key-schema AttributeName=id,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST \
    >/dev/null
fi

aws-floci dynamodb put-item \
  --table-name "$TABLE" \
  --item '{"id":{"S":"user-001"},"name":{"S":"Tuhin"},"environment":{"S":"floci"}}'

DDB_NAME="$(
  aws-floci dynamodb get-item \
    --table-name "$TABLE" \
    --key '{"id":{"S":"user-001"}}' \
    --query 'Item.name.S' \
    --output text
)"

[ "$DDB_NAME" = "Tuhin" ]
echo "DYNAMODB_TEST=PASS"

echo "=== SSM Parameter Store ==="
aws-floci ssm put-parameter \
  --name "$PARAM" \
  --type String \
  --value development \
  --overwrite \
  >/dev/null

SSM_VALUE="$(
  aws-floci ssm get-parameter \
    --name "$PARAM" \
    --query 'Parameter.Value' \
    --output text
)"

[ "$SSM_VALUE" = "development" ]
echo "SSM_TEST=PASS"

echo "=== Secrets Manager ==="
if aws-floci secretsmanager describe-secret --secret-id "$SECRET" >/dev/null 2>&1; then
  aws-floci secretsmanager put-secret-value \
    --secret-id "$SECRET" \
    --secret-string "$EXPECTED_SECRET" \
    >/dev/null
else
  aws-floci secretsmanager create-secret \
    --name "$SECRET" \
    --secret-string "$EXPECTED_SECRET" \
    >/dev/null
fi

SECRET_VALUE="$(
  aws-floci secretsmanager get-secret-value \
    --secret-id "$SECRET" \
    --query SecretString \
    --output text
)"

[ "$SECRET_VALUE" = "$EXPECTED_SECRET" ]
echo "SECRETS_MANAGER_TEST=PASS"

echo "FLOCI_CORE_AWS_SMOKE_TEST=PASS"
