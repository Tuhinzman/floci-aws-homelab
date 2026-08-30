#!/usr/bin/env bash
set -euo pipefail

BUCKET="${FLOCI_TEST_BUCKET:-floci-test-bucket}"
QUEUE="${FLOCI_TEST_QUEUE:-floci-test-orders}"
TABLE="${FLOCI_TEST_TABLE:-FlociTestUsers}"
PARAM="${FLOCI_TEST_PARAM:-/floci/test/environment}"
SECRET="${FLOCI_TEST_SECRET:-floci/test/database}"

aws-floci sts get-caller-identity

aws-floci s3 mb "s3://${BUCKET}" 2>/dev/null || true
echo "hello from floci" >/tmp/floci-test.txt
aws-floci s3 cp /tmp/floci-test.txt "s3://${BUCKET}/hello.txt"
aws-floci s3 cp "s3://${BUCKET}/hello.txt" -

QUEUE_URL="$(aws-floci sqs create-queue --queue-name "$QUEUE" --query QueueUrl --output text)"
aws-floci sqs send-message --queue-url "$QUEUE_URL" --message-body '{"order_id":"12345","status":"created"}' >/dev/null
aws-floci sqs receive-message --queue-url "$QUEUE_URL" --max-number-of-messages 1

if ! aws-floci dynamodb describe-table --table-name "$TABLE" >/dev/null 2>&1; then
  aws-floci dynamodb create-table \
    --table-name "$TABLE" \
    --attribute-definitions AttributeName=id,AttributeType=S \
    --key-schema AttributeName=id,KeyType=HASH \
    --billing-mode PAY_PER_REQUEST >/dev/null
fi

aws-floci dynamodb put-item --table-name "$TABLE" --item '{"id":{"S":"user-001"},"name":{"S":"Tuhin"},"environment":{"S":"floci"}}'
aws-floci dynamodb get-item --table-name "$TABLE" --key '{"id":{"S":"user-001"}}'

aws-floci ssm put-parameter --name "$PARAM" --type String --value development --overwrite >/dev/null
aws-floci ssm get-parameter --name "$PARAM"

if aws-floci secretsmanager describe-secret --secret-id "$SECRET" >/dev/null 2>&1; then
  aws-floci secretsmanager put-secret-value --secret-id "$SECRET" --secret-string '{"username":"flociuser","password":"test-only-password"}' >/dev/null
else
  aws-floci secretsmanager create-secret --name "$SECRET" --secret-string '{"username":"flociuser","password":"test-only-password"}' >/dev/null
fi
aws-floci secretsmanager get-secret-value --secret-id "$SECRET"

echo "FLOCI_CORE_AWS_SMOKE_TEST=PASS"
