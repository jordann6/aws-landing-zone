"""Backup freshness check: newest-object age, object count, and the empty-bucket case."""
import importlib
import os
import sys
import types
from datetime import datetime, timedelta, timezone
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lambda"))
os.environ.update({"BUCKET_NAME": "backup-verify-test", "AWS_DEFAULT_REGION": "us-east-1"})

import backup_check as app  # noqa: E402


def load(pages):
    importlib.reload(app)
    app.s3 = mock.Mock()
    app.s3.get_paginator.return_value.paginate.return_value = pages
    app.cloudwatch = mock.Mock()
    return app


def metrics(a):
    data = a.cloudwatch.put_metric_data.call_args.kwargs["MetricData"]
    return {m["MetricName"]: m["Value"] for m in data}


def test_reports_newest_age_and_count_across_pages():
    now = datetime.now(timezone.utc)
    pages = [
        {"Contents": [{"LastModified": now - timedelta(hours=50)}, {"LastModified": now - timedelta(hours=5)}]},
        {"Contents": [{"LastModified": now - timedelta(hours=20)}]},
    ]
    a = load(pages)
    result = a.lambda_handler({}, types.SimpleNamespace())
    assert result["object_count"] == 3
    assert 4.9 <= result["newest_age_hours"] <= 5.2
    assert metrics(a)["ObjectCount"] == 3


def test_empty_bucket_reports_huge_age_so_the_alarm_fires():
    a = load([{}])
    result = a.lambda_handler({}, types.SimpleNamespace())
    assert result["object_count"] == 0
    assert result["newest_age_hours"] == 9999.0
    assert metrics(a)["NewestObjectAgeHours"] == 9999.0
