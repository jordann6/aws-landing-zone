"""Uptime checker: retry once on failure, metrics emitted, no alerting from the Lambda."""
import importlib
import os
import sys
import types
from unittest import mock

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lambda"))
os.environ.update({
    "TABLE_NAME": "uptime-monitor-logs",
    "CHECK_URL": "https://example.test",
    "AWS_DEFAULT_REGION": "us-east-1",
})

import uptime_checker as app  # noqa: E402


def load(http_results, ssl_days=60):
    importlib.reload(app)
    app.cloudwatch = mock.Mock()
    app.table = mock.Mock()
    app.RETRY_DELAY_SECONDS = 0
    app.http_check = mock.Mock(side_effect=http_results)
    app.ssl_days_remaining = mock.Mock(return_value=ssl_days)
    return app


def metrics(a):
    data = a.cloudwatch.put_metric_data.call_args.kwargs["MetricData"]
    return {m["MetricName"]: m["Value"] for m in data}


def test_healthy_site_checks_once_and_reports_up():
    a = load([(200, 120, True, True, None)])
    result = a.lambda_handler({}, types.SimpleNamespace())
    assert result["healthy"] is True
    assert a.http_check.call_count == 1
    assert metrics(a)["IsHealthy"] == 1
    assert metrics(a)["SSLDaysRemaining"] == 60


def test_one_transient_failure_is_retried_and_not_reported_down():
    a = load([(None, 10000, False, False, "timeout"), (200, 150, True, True, None)])
    result = a.lambda_handler({}, types.SimpleNamespace())
    assert result["healthy"] is True
    assert a.http_check.call_count == 2
    assert metrics(a)["IsHealthy"] == 1


def test_two_failures_report_down_and_log_the_error():
    a = load([(503, 90, False, False, "Service Unavailable")] * 2)
    result = a.lambda_handler({}, types.SimpleNamespace())
    assert result["healthy"] is False
    assert metrics(a)["IsHealthy"] == 0
    item = a.table.put_item.call_args.kwargs["Item"]
    assert item["is_healthy"] is False and item["error"] == "Service Unavailable"


def test_unreadable_certificate_omits_the_ssl_metric():
    a = load([(200, 100, True, True, None)], ssl_days=None)
    a.lambda_handler({}, types.SimpleNamespace())
    assert "SSLDaysRemaining" not in metrics(a)
