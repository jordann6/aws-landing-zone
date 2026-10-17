"""Five-minute website check. Emits CloudWatch metrics and a DynamoDB log row.

Alerting is not done here: CloudWatch alarms read the metrics and notify the ops
topic, so a dead checker (no metrics) alarms too. One retry suppresses a single
transient failure before IsHealthy is reported as 0.
"""
import json
import os
import socket
import ssl
import time
import urllib.error
import urllib.request
from datetime import datetime, timedelta, timezone

import boto3

TABLE_NAME = os.environ["TABLE_NAME"]
CHECK_URL = os.environ["CHECK_URL"]
CONTENT_CHECK = os.environ.get("CONTENT_CHECK", "")
NAMESPACE = os.environ.get("METRIC_NAMESPACE", "UptimeMonitor")
TTL_DAYS = 90
RETRY_DELAY_SECONDS = 5

cloudwatch = boto3.client("cloudwatch")
table = boto3.resource("dynamodb").Table(TABLE_NAME)


def http_check(url, content_check=""):
    """Return (status_code, latency_ms, healthy, content_ok, error)."""
    start = time.monotonic()
    try:
        req = urllib.request.Request(url, method="GET", headers={"User-Agent": "UptimeMonitor/2.0"})
        with urllib.request.urlopen(req, timeout=10) as resp:  # nosec B310: https URL from config
            status = resp.getcode()
            body = resp.read(8192).decode("utf-8", errors="ignore")
        latency = round((time.monotonic() - start) * 1000)
        content_ok = content_check.lower() in body.lower() if content_check else True
        return status, latency, 200 <= status < 400 and content_ok, content_ok, None
    except urllib.error.HTTPError as exc:
        return exc.code, round((time.monotonic() - start) * 1000), False, False, str(exc.reason)
    except Exception as exc:  # DNS, TLS, timeout: all mean "not healthy"
        return None, round((time.monotonic() - start) * 1000), False, False, str(exc)


def ssl_days_remaining(hostname):
    """Days until the certificate expires, or None when it cannot be read."""
    try:
        ctx = ssl.create_default_context()
        with socket.create_connection((hostname, 443), timeout=10) as raw:
            with ctx.wrap_socket(raw, server_hostname=hostname) as sock:
                cert = sock.getpeercert()
        expiry = datetime.strptime(cert["notAfter"], "%b %d %H:%M:%S %Y %Z").replace(tzinfo=timezone.utc)
        return (expiry - datetime.now(timezone.utc)).days
    except Exception:
        return None


def put_metrics(metrics):
    cloudwatch.put_metric_data(
        Namespace=NAMESPACE,
        MetricData=[
            {
                "MetricName": name,
                "Value": value,
                "Unit": unit,
                "Dimensions": [{"Name": "URL", "Value": CHECK_URL}],
            }
            for name, value, unit in metrics
        ],
    )


def lambda_handler(event, context):
    now = datetime.now(timezone.utc)
    check_id = CHECK_URL.replace("https://", "").replace("http://", "").rstrip("/")
    hostname = check_id.split("/")[0]

    status, latency, healthy, content_ok, error = http_check(CHECK_URL, CONTENT_CHECK)
    if not healthy:
        time.sleep(RETRY_DELAY_SECONDS)
        status, latency, healthy, content_ok, error = http_check(CHECK_URL, CONTENT_CHECK)

    ssl_days = ssl_days_remaining(hostname) if CHECK_URL.startswith("https://") else None

    metrics = [("IsHealthy", 1 if healthy else 0, "None"), ("LatencyMs", latency, "Milliseconds")]
    if ssl_days is not None:
        metrics.append(("SSLDaysRemaining", ssl_days, "Count"))
    put_metrics(metrics)

    item = {
        "check_id": check_id,
        "timestamp": now.isoformat(),
        "status_code": status or 0,
        "latency_ms": latency,
        "is_healthy": healthy,
        "content_ok": content_ok,
        "ttl": int((now + timedelta(days=TTL_DAYS)).timestamp()),
    }
    if ssl_days is not None:
        item["ssl_days_remaining"] = ssl_days
    if error:
        item["error"] = error
    table.put_item(Item=item)

    print(json.dumps(item, default=str))
    return {"healthy": healthy, "status_code": status, "latency_ms": latency, "ssl_days_remaining": ssl_days}
