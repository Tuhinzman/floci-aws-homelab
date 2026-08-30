#!/usr/bin/env bash
set -euo pipefail

FLOCI_DIR="${FLOCI_DIR:-/opt/floci}"
BUCKET="${FLOCI_TEST_BUCKET:-floci-test-bucket}"
QUEUE="${FLOCI_TEST_QUEUE:-floci-test-orders}"
TABLE="${FLOCI_TEST_TABLE:-FlociTestUsers}"
PARAM="${FLOCI_TEST_PARAM:-/floci/test/environment}"
SECRET="${FLOCI_TEST_SECRET:-floci/test/database}"

cd "$FLOCI_DIR"

sudo docker compose restart floci

for attempt in $(seq 1 30); do
  HEALTH="$(sudo docker inspect floci --format '{{if .State.Health}}{{.State.Health.Status}}{{else}}none{{end}}')"
  if [ "$HEALTH" = "healthy" ]; then
    break
  fi
  sleep 1
done

[ "${HEALTH:-none}" = "healthy" ]

S3_OBJECT="$(aws-floci s3 cp "s3://${BUCKET}/hello.txt" -)"
QUEUE_URL="$(aws-floci sqs get-queue-url --queue-name "$QUEUE" --query QueueUrl --output text)"
DDB_NAME="$(aws-floci dynamodb get-item --table-name "$TABLE" --key '{"id":{"S":"user-001"}}' --query 'Item.name.S' --output text)"
SSM_VALUE="$(aws-floci ssm get-parameter --name "$PARAM" --query 'Parameter.Value' --output text)"
SECRET_NAME="$(aws-floci secretsmanager describe-secret --secret-id "$SECRET" --query Name --output text)"

[ "$S3_OBJECT" = "hello from floci" ]
[ "$QUEUE_URL" != "None" ]
[ "$DDB_NAME" = "Tuhin" ]
[ "$SSM_VALUE" = "development" ]
[ "$SECRET_NAME" = "$SECRET" ]

echo "S3_PERSISTENCE=PASS"
echo "SQS_PERSISTENCE=PASS"
echo "DYNAMODB_PERSISTENCE=PASS"
echo "SSM_PERSISTENCE=PASS"
echo "SECRETS_MANAGER_PERSISTENCE=PASS"
echo "FLOCI_PERSISTENCE_VALIDATION=PASS"
