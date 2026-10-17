"""Heartbeat producer: one object under the prefix, explicit SSE-KMS header, synthetic body."""
import importlib
import json
import os
import sys
import types
from datetime import datetime, timezone
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lambda"))
os.environ.update({"BUCKET_NAME": "backup-verify-test", "AWS_DEFAULT_REGION": "us-east-1",
                   "KMS_KEY_ARN": "arn:aws:kms:us-east-1:111111111111:key/test"})

import heartbeat as app  # noqa: E402


def load():
    importlib.reload(app)
    app.s3 = mock.Mock()
    return app


def test_writes_one_object_under_the_prefix():
    a = load()
    result = a.lambda_handler({}, types.SimpleNamespace())
    a.s3.put_object.assert_called_once()
    kwargs = a.s3.put_object.call_args.kwargs
    assert kwargs["Bucket"] == "backup-verify-test"
    assert kwargs["Key"].startswith("heartbeat/")
    assert kwargs["Key"] == result["key"]


def test_body_is_marked_synthetic():
    a = load()
    a.lambda_handler({}, types.SimpleNamespace())
    body = json.loads(a.s3.put_object.call_args.kwargs["Body"])
    assert body["synthetic"] is True
    assert body["source"] == "backup-verify-heartbeat"


def test_sends_the_encryption_header():
    # The require-s3-encryption SCP denies PutObject without this header, even
    # though the bucket default would encrypt the object.
    a = load()
    a.lambda_handler({}, types.SimpleNamespace())
    kwargs = a.s3.put_object.call_args.kwargs
    assert kwargs["ServerSideEncryption"] == "aws:kms"
    assert kwargs["SSEKMSKeyId"] == "arn:aws:kms:us-east-1:111111111111:key/test"
    assert kwargs["BucketKeyEnabled"] is True


def test_keys_sort_by_time():
    a = load()
    early = a.object_key(datetime(2026, 10, 17, 5, 0, tzinfo=timezone.utc))
    late = a.object_key(datetime(2026, 10, 17, 11, 0, tzinfo=timezone.utc))
    assert early == "heartbeat/2026/10/17/050000Z.json"
    assert early < late
