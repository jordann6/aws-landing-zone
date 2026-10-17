import json
import os
import time
from datetime import datetime, timezone

import boto3
from botocore.exceptions import ClientError

ec2 = boto3.client("ec2")
sns = boto3.client("sns")
cw = boto3.client("cloudwatch")
ddb = boto3.client("dynamodb")

SNS_TOPIC_ARN = os.environ["SNS_TOPIC_ARN"]

# --- Guardrail configuration ----------------------------------------------
STATE_TABLE = os.environ.get("STATE_TABLE", "")
ONCALL_TOPIC_ARN = os.environ.get("ONCALL_TOPIC_ARN", SNS_TOPIC_ARN)
COOLDOWN_SECONDS = int(os.environ.get("COOLDOWN_SECONDS", "900"))          # 15 min debounce
CIRCUIT_WINDOW_SECONDS = int(os.environ.get("CIRCUIT_WINDOW_SECONDS", "3600"))  # 1 hr
MAX_ATTEMPTS = int(os.environ.get("MAX_ATTEMPTS", "3"))                     # trip after N in window
DRY_RUN = os.environ.get("DRY_RUN", "false").lower() == "true"
METRIC_NAMESPACE = os.environ.get("METRIC_NAMESPACE", "Remediation")
ALARM_PREFIX = os.environ.get("ALARM_PREFIX", "remediate-cpu-")



# --- Observability ---------------------------------------------------------

def _emit_metric(name: str, action: str, resource_id: str, value: float = 1.0, unit: str = "Count",
                 extra_dims: dict[str, str] | None = None) -> None:
    """Emit a CloudWatch custom metric. Never let telemetry failures break remediation."""
    dimensions = [
        {"Name": "Action", "Value": action},
        {"Name": "ResourceId", "Value": resource_id},
    ]
    dimensions += [{"Name": k, "Value": v} for k, v in (extra_dims or {}).items()]
    try:
        cw.put_metric_data(
            Namespace=METRIC_NAMESPACE,
            MetricData=[{
                "MetricName": name,
                "Value": value,
                "Unit": unit,
                "Dimensions": dimensions,
            }],
        )
    except ClientError as e:
        print(json.dumps({"level": "warn", "message": "metric emit failed", "error": str(e)}))


def _notify(topic_arn: str, subject: str, payload: dict, request_id: str) -> None:
    sns.publish(
        TopicArn=topic_arn,
        Subject=subject[:100],  # SNS subject hard limit
        Message=json.dumps({**payload, "request_id": request_id}, default=str),
    )


def _event_latency_ms(trigger_event: dict) -> float | None:
    """Time from alarm firing to remediation, our time-to-remediate signal."""
    ts = trigger_event.get("time")
    if not ts:
        return None
    try:
        fired = datetime.fromisoformat(ts.replace("Z", "+00:00"))
        return (datetime.now(timezone.utc) - fired).total_seconds() * 1000.0
    except (ValueError, AttributeError):
        return None


# --- Guardrail gate (cooldown + circuit breaker) ---------------------------
#
# Safety model, one place:
# - State is one DynamoDB item per resource+action: recent attempt timestamps, a
#   version counter, and when the last escalation page went out.
# - Every write is conditional on the version read, so two invocations that read the
#   same state cannot both proceed: the loser gets COOLDOWN.
# - An attempt is reserved BEFORE the action. A failed reboot therefore still counts
#   against the budget (a reboot that fails repeatedly should trip the breaker).
# - Dry runs read the state but never write attempts, so drills cannot use up the
#   real budget.
# - When the circuit is open the on-call page goes out once per window, not on every
#   alarm re-fire.

class GateDecision:
    PROCEED = "proceed"
    COOLDOWN = "cooldown"          # too soon since last action, or lost a race
    CIRCUIT_OPEN = "circuit_open"  # too many attempts in window, escalate to a human


def _load_state(key: str) -> dict:
    """Return {"attempts": [...], "version": int, "escalated_at": int}; empty when absent."""
    empty = {"attempts": [], "version": 0, "escalated_at": 0}
    if not STATE_TABLE:
        return empty
    try:
        item = ddb.get_item(
            TableName=STATE_TABLE,
            Key={"resource_action": {"S": key}},
            ConsistentRead=True,
        ).get("Item")
    except ClientError as e:
        print(json.dumps({"level": "warn", "message": "state read failed", "error": str(e)}))
        return empty
    if not item:
        return empty
    return {
        "attempts": [int(a["N"]) for a in item.get("attempts", {}).get("L", [])],
        "version": int(item.get("version", {}).get("N", "0")),
        "escalated_at": int(item.get("escalated_at", {}).get("N", "0")),
    }


def _save_state(key: str, state: dict, attempts: list[int], escalated_at: int) -> bool:
    """Conditional write on the version that was read. False means another invocation won."""
    if not STATE_TABLE:
        return True
    try:
        ddb.put_item(
            TableName=STATE_TABLE,
            Item={
                "resource_action": {"S": key},
                "attempts": {"L": [{"N": str(a)} for a in attempts]},
                "version": {"N": str(state["version"] + 1)},
                "escalated_at": {"N": str(escalated_at)},
                "expires_at": {"N": str(int(time.time()) + CIRCUIT_WINDOW_SECONDS * 2)},
            },
            ConditionExpression="attribute_not_exists(resource_action) OR version = :v",
            ExpressionAttributeValues={":v": {"N": str(state["version"])}},
        )
        return True
    except ClientError as e:
        if e.response.get("Error", {}).get("Code") == "ConditionalCheckFailedException":
            return False
        raise


def evaluate_gate(resource_id: str, action: str) -> tuple[str, dict, list[int]]:
    """Decide whether remediation may proceed. Returns (decision, state, pruned_attempts)."""
    key = f"{resource_id}#{action}"
    now = int(time.time())
    state = _load_state(key)
    attempts = [t for t in state["attempts"] if now - t < CIRCUIT_WINDOW_SECONDS]

    if len(attempts) >= MAX_ATTEMPTS:
        return GateDecision.CIRCUIT_OPEN, state, attempts
    if attempts and (now - max(attempts)) < COOLDOWN_SECONDS:
        return GateDecision.COOLDOWN, state, attempts
    return GateDecision.PROCEED, state, attempts


def reserve_attempt(resource_id: str, action: str, state: dict, attempts: list[int]) -> bool:
    """Record the attempt before acting. False when a concurrent invocation got there first."""
    key = f"{resource_id}#{action}"
    return _save_state(key, state, attempts + [int(time.time())], state["escalated_at"])


def escalate(resource_id: str, action: str, state: dict, attempts: list[int],
             request_id: str, trigger_event: dict) -> dict:
    """Circuit is open, prior remediations did not hold. Page a human once per window."""
    now = int(time.time())
    payload = {
        "status": "escalated",
        "reason": "circuit_open",
        "action": action,
        "resource_id": resource_id,
        "attempts_in_window": len(attempts),
        "window_seconds": CIRCUIT_WINDOW_SECONDS,
        "detail": f"{action} fired {len(attempts)}x in {CIRCUIT_WINDOW_SECONDS // 60} min without resolving; automated remediation halted, manual intervention required.",
        "trigger": trigger_event,
    }
    already_paged = state["escalated_at"] and now - state["escalated_at"] < CIRCUIT_WINDOW_SECONDS
    if already_paged:
        payload["paged"] = False
        _emit_metric("EscalationSuppressed", action, resource_id)
    elif _save_state(f"{resource_id}#{action}", state, attempts, now):
        payload["paged"] = True
        _emit_metric("EscalationTriggered", action, resource_id)
        _notify(ONCALL_TOPIC_ARN, f"[ESCALATION] {action} on {resource_id} not resolving, page on-call", payload, request_id)
    else:
        payload["paged"] = False  # a concurrent invocation recorded the page
    print(json.dumps({"level": "error", **payload, "request_id": request_id}, default=str))
    return payload


# --- Remediation actions ---------------------------------------------------

def reboot_instance(instance_id: str, request_id: str, trigger_event: dict) -> dict:
    if not DRY_RUN:
        ec2.reboot_instances(InstanceIds=[instance_id])
    payload = {
        "status": "success",
        "action": "ec2:RebootInstances",
        "instance_id": instance_id,
        "dry_run": DRY_RUN,
        "trigger": trigger_event,
    }
    _notify(SNS_TOPIC_ARN, f"[Remediation] EC2 reboot {'(dry run) ' if DRY_RUN else ''}triggered, {instance_id}", payload, request_id)
    return payload


ACTIONS = {
    "reboot": (reboot_instance, lambda ev: ev.get("instance_id")),
}


def alarm_details(event: dict) -> tuple[str | None, str | None]:
    """(alarm name, instance id) from a CloudWatch Alarm State Change event; None when absent."""
    detail = event.get("detail", {})
    instance_id = None
    for metric in detail.get("configuration", {}).get("metrics", []):
        dims = metric.get("metricStat", {}).get("metric", {}).get("dimensions", {})
        if dims.get("InstanceId"):
            instance_id = dims["InstanceId"]
            break
    return detail.get("alarmName"), instance_id


def alarm_still_firing(alarm_name: str) -> bool:
    """Recheck current state, so a delayed event never reboots after the alarm recovered."""
    alarms = cw.describe_alarms(AlarmNames=[alarm_name]).get("MetricAlarms", [])
    return bool(alarms) and alarms[0].get("StateValue") == "ALARM"


def is_monitored(instance_id: str) -> bool:
    """Only instances tagged Monitored=true may be rebooted (IAM enforces the same)."""
    reservations = ec2.describe_instances(InstanceIds=[instance_id])["Reservations"]
    tags = {t["Key"]: t["Value"] for t in reservations[0]["Instances"][0].get("Tags", [])}
    return tags.get("Monitored") == "true"


# --- Orchestration ---------------------------------------------------------

def run_remediation(action: str, resource_id: str, request_id: str, trigger_event: dict) -> dict:
    """Gate every remediation through cooldown + circuit breaker, then act, verify, meter."""
    handler, _ = ACTIONS[action]

    decision, state, attempts = evaluate_gate(resource_id, action)

    if decision == GateDecision.CIRCUIT_OPEN:
        return escalate(resource_id, action, state, attempts, request_id, trigger_event)

    if decision == GateDecision.PROCEED and not DRY_RUN:
        if not reserve_attempt(resource_id, action, state, attempts):
            decision = GateDecision.COOLDOWN  # lost the race, the winner is acting

    if decision == GateDecision.COOLDOWN:
        payload = {
            "status": "skipped",
            "reason": "cooldown",
            "action": action,
            "resource_id": resource_id,
            "cooldown_seconds": COOLDOWN_SECONDS,
            "detail": f"{action} ran within the last {COOLDOWN_SECONDS // 60} min or is in flight; debounced.",
        }
        _emit_metric("RemediationSkipped", action, resource_id)
        print(json.dumps({"level": "info", **payload, "request_id": request_id}))
        return payload

    print(json.dumps({"level": "info", "message": "remediating", "action": action,
                      "resource_id": resource_id, "dry_run": DRY_RUN, "request_id": request_id}))
    try:
        result = handler(resource_id, request_id, trigger_event)
    except ClientError as e:
        _emit_metric("RemediationFailure", action, resource_id)
        payload = {"status": "failure", "action": action, "resource_id": resource_id, "error": str(e)}
        _notify(ONCALL_TOPIC_ARN, f"[Remediation FAILED] {action} on {resource_id}", payload, request_id)
        print(json.dumps({"level": "error", **payload, "request_id": request_id}))
        raise

    # DryRun splits drills from real actions, so a dashboard can count reboots alone.
    _emit_metric("RemediationSuccess", action, resource_id,
                 extra_dims={"DryRun": "true" if DRY_RUN else "false"})
    latency = _event_latency_ms(trigger_event)
    if latency is not None:
        _emit_metric("TimeToRemediateMs", action, resource_id, value=latency, unit="Milliseconds")
    return result


def _skip(reason: str, resource_id: str | None, request_id: str, **extra) -> dict:
    payload = {"status": "skipped", "reason": reason, "resource_id": resource_id, **extra}
    print(json.dumps({"level": "warn", **payload, "request_id": request_id}))
    return payload


def lambda_handler(event, context):
    request_id = getattr(context, "aws_request_id", "local")
    print(json.dumps({"message": "Received event", "request_id": request_id, "event": event}, default=str))

    # EventBridge CloudWatch Alarm state-change events: reboot the alarming instance
    if event.get("source") == "aws.cloudwatch":
        alarm_name, instance_id = alarm_details(event)
        if not alarm_name or not instance_id:
            return _skip("malformed_event", instance_id, request_id)
        if not alarm_name.startswith(ALARM_PREFIX):
            return _skip("unexpected_alarm", instance_id, request_id, alarm_name=alarm_name)
        if not alarm_still_firing(alarm_name):
            return _skip("alarm_recovered", instance_id, request_id, alarm_name=alarm_name)
        if not is_monitored(instance_id):
            return _skip("not_monitored", instance_id, request_id)
        return run_remediation("reboot", instance_id, request_id, event)

    # Manual / test invocations: route on action field
    action = event.get("action", "reboot")
    if action not in ACTIONS:
        raise ValueError(f"unknown action '{action}'; expected one of {list(ACTIONS)}")

    _, resource_of = ACTIONS[action]
    resource_id = resource_of(event)
    if not resource_id:
        raise ValueError(f"action '{action}' requires a target resource id")
    if not is_monitored(resource_id):
        return _skip("not_monitored", resource_id, request_id)

    return run_remediation(action, resource_id, request_id, event)
