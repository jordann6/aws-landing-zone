"""Synthetic heartbeat producer for the landing bucket.

Writes one tiny object under the heartbeat prefix on a schedule, so the freshness
check has something to measure. It proves the check and the stale alarm, not that
a real backup ran or can be restored. The encryption header is sent explicitly
because the require-s3-encryption SCP denies any PutObject without one, even
when the bucket default would encrypt the object anyway.
"""
import json
import os
from datetime import datetime, timezone

import boto3

BUCKET = os.environ["BUCKET_NAME"]
PREFIX = os.environ.get("HEARTBEAT_PREFIX", "heartbeat/")
KMS_KEY_ARN = os.environ["KMS_KEY_ARN"]

s3 = boto3.client("s3")


def object_key(now):
    return f"{PREFIX}{now.strftime('%Y/%m/%d/%H%M%SZ')}.json"


def lambda_handler(event, context):
    now = datetime.now(timezone.utc)
    key = object_key(now)
    body = {"written_at": now.isoformat(), "source": "backup-verify-heartbeat", "synthetic": True}
    s3.put_object(Bucket=BUCKET, Key=key, Body=json.dumps(body).encode(),
                  ContentType="application/json", ServerSideEncryption="aws:kms",
                  SSEKMSKeyId=KMS_KEY_ARN, BucketKeyEnabled=True)
    result = {"bucket": BUCKET, "key": key}
    print(json.dumps(result))
    return result
