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
        message_id = (
            record.get("messageId")
            or record.get("MessageId")
            or "unknown"
        )

        dynamodb.put_item(
            TableName=TABLE_NAME,
            Item={
                "order_id": {"S": order_id},
                "status": {"S": status},
                "source": {"S": "terraform-sqs-lambda"},
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
