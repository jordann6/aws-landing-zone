"""Remediation safety tests. AWS clients are stubbed; DynamoDB is an in-memory fake
that implements the conditional write, so the race behavior is exercised for real."""
import importlib
import os
import sys
import time
import types
from unittest import mock

import pytest
from botocore.exceptions import ClientError

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "lambda"))

os.environ.update({
    "SNS_TOPIC_ARN": "arn:aws:sns:us-east-1:111122223333:remediation-alerts",
    "ONCALL_TOPIC_ARN": "arn:aws:sns:us-east-1:111122223333:remediation-oncall",
    "STATE_TABLE": "remediation-state",
    "COOLDOWN_SECONDS": "900",
    "CIRCUIT_WINDOW_SECONDS": "3600",
    "MAX_ATTEMPTS": "3",
    "AWS_DEFAULT_REGION": "us-east-1",
})

import remediation as app  # noqa: E402

INSTANCE = "i-abc123"


class FakeDynamo:
    """get_item/put_item with the one condition the Lambda uses."""

    def __init__(self):
        self.items = {}

    def get_item(self, TableName, Key, ConsistentRead):
        item = self.items.get(Key["resource_action"]["S"])
        return {"Item": item} if item else {}

    def put_item(self, TableName, Item, ConditionExpression, ExpressionAttributeValues):
        key = Item["resource_action"]["S"]
        current = self.items.get(key)
        if current is not None and current["version"]["N"] != ExpressionAttributeValues[":v"]["N"]:
            raise ClientError({"Error": {"Code": "ConditionalCheckFailedException"}}, "PutItem")
        self.items[key] = Item


def load(dry_run="false", firing=True, monitored=True):
    os.environ["DRY_RUN"] = dry_run
    importlib.reload(app)
    app.ec2, app.sns, app.cw = mock.Mock(), mock.Mock(), mock.Mock()
    app.ddb = FakeDynamo()
    tags = [{"Key": "Monitored", "Value": "true"}] if monitored else []
    app.ec2.describe_instances.return_value = {"Reservations": [{"Instances": [{"Tags": tags}]}]}
    app.cw.describe_alarms.return_value = {
        "MetricAlarms": [{"StateValue": "ALARM" if firing else "OK"}]
    }
    return app


def alarm_event(alarm=f"remediate-cpu-{INSTANCE}", instance=INSTANCE):
    return {
        "source": "aws.cloudwatch",
        "time": "2026-10-16T12:00:00Z",
        "detail": {
            "alarmName": alarm,
            "state": {"value": "ALARM"},
            "configuration": {"metrics": [{"metricStat": {"metric": {"dimensions": {"InstanceId": instance}}}}]},
        },
    }


CTX = types.SimpleNamespace(aws_request_id="test-req")


def test_alarm_reboots_monitored_instance():
    a = load()
    result = a.lambda_handler(alarm_event(), CTX)
    assert result["status"] == "success"
    a.ec2.reboot_instances.assert_called_once_with(InstanceIds=[INSTANCE])


def test_duplicate_event_does_not_reboot_twice():
    a = load()
    a.lambda_handler(alarm_event(), CTX)
    second = a.lambda_handler(alarm_event(), CTX)
    assert second["reason"] == "cooldown"
    assert a.ec2.reboot_instances.call_count == 1


def test_lost_race_does_not_reboot():
    """Two invocations read the same state; only the first conditional write wins."""
    a = load()
    decision, state, attempts = a.evaluate_gate(INSTANCE, "reboot")
    assert a.reserve_attempt(INSTANCE, "reboot", state, attempts) is True
    assert a.reserve_attempt(INSTANCE, "reboot", state, attempts) is False


@pytest.mark.parametrize("event", [
    {"source": "aws.cloudwatch"},
    {"source": "aws.cloudwatch", "detail": {"alarmName": "remediate-cpu-x"}},
    {"source": "aws.cloudwatch", "detail": {"configuration": {"metrics": []}}},
])
def test_malformed_events_do_nothing(event):
    a = load()
    assert a.lambda_handler(event, CTX)["reason"] == "malformed_event"
    a.ec2.reboot_instances.assert_not_called()


def test_unexpected_alarm_name_does_nothing():
    a = load()
    result = a.lambda_handler(alarm_event(alarm="some-other-alarm"), CTX)
    assert result["reason"] == "unexpected_alarm"
    a.ec2.reboot_instances.assert_not_called()


def test_unmonitored_instance_does_nothing():
    a = load(monitored=False)
    assert a.lambda_handler(alarm_event(), CTX)["reason"] == "not_monitored"
    a.ec2.reboot_instances.assert_not_called()


def test_manual_invoke_also_requires_monitored_tag():
    a = load(monitored=False)
    assert a.lambda_handler({"action": "reboot", "instance_id": INSTANCE}, CTX)["reason"] == "not_monitored"
    a.ec2.reboot_instances.assert_not_called()


def test_recovered_alarm_does_not_reboot():
    a = load(firing=False)
    assert a.lambda_handler(alarm_event(), CTX)["reason"] == "alarm_recovered"
    a.ec2.reboot_instances.assert_not_called()


def test_dry_run_reports_but_does_not_reboot_or_consume_budget():
    a = load(dry_run="true")
    for _ in range(5):
        result = a.lambda_handler(alarm_event(), CTX)
        assert result["status"] == "success" and result["dry_run"] is True
    a.ec2.reboot_instances.assert_not_called()
    assert a.ddb.items == {}  # nothing recorded, so the real budget is untouched


def test_failed_reboot_counts_against_the_budget():
    a = load()
    a.ec2.reboot_instances.side_effect = ClientError({"Error": {"Code": "UnauthorizedOperation"}}, "RebootInstances")
    with pytest.raises(ClientError):
        a.lambda_handler(alarm_event(), CTX)
    state = a.ddb.items[f"{INSTANCE}#reboot"]
    assert len(state["attempts"]["L"]) == 1


def _open_circuit(a):
    now = int(time.time())
    a.ddb.items[f"{INSTANCE}#reboot"] = {
        "resource_action": {"S": f"{INSTANCE}#reboot"},
        "attempts": {"L": [{"N": str(now - 3000 + i)} for i in range(3)]},
        "version": {"N": "3"},
        "escalated_at": {"N": "0"},
    }


def test_open_circuit_pages_once_per_window():
    a = load()
    _open_circuit(a)
    first = a.lambda_handler(alarm_event(), CTX)
    second = a.lambda_handler(alarm_event(), CTX)
    third = a.lambda_handler(alarm_event(), CTX)
    assert first["status"] == "escalated" and first["paged"] is True
    assert second["paged"] is False and third["paged"] is False
    assert a.sns.publish.call_count == 1
    a.ec2.reboot_instances.assert_not_called()


def test_circuit_pages_again_after_the_window():
    a = load()
    _open_circuit(a)
    a.lambda_handler(alarm_event(), CTX)
    item = a.ddb.items[f"{INSTANCE}#reboot"]
    item["escalated_at"] = {"N": str(int(time.time()) - 4000)}
    again = a.lambda_handler(alarm_event(), CTX)
    assert again["paged"] is True
