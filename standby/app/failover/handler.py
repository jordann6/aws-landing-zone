"""Failover manager.

Runs in the standby region. Invoked by EventBridge when the primary health
alarm fires, or manually with {"action": "failover"}. Route 53 handles the
stateless traffic shift on its own, this function handles the stateful half:
promoting the cross-region read replica to a standalone writable primary.
"""

import json
import os

import boto3

rds = boto3.client("rds")
sns = boto3.client("sns")


def _notify(subject, message):
    sns.publish(
        TopicArn=os.environ["SNS_TOPIC_ARN"],
        Subject=subject[:100],
        Message=message,
    )


def _trigger_description(event):
    if event.get("action") == "failover":
        return "manual invocation: " + event.get("reason", "no reason given")
    detail = event.get("detail", {})
    if detail.get("alarmName"):
        return f"CloudWatch alarm {detail['alarmName']} entered ALARM"
    return "unrecognized event"


def lambda_handler(event, _context):
    replica_id = os.environ["REPLICA_IDENTIFIER"]
    trigger = _trigger_description(event)
    print(f"Failover requested, trigger: {trigger}")

    db = rds.describe_db_instances(DBInstanceIdentifier=replica_id)["DBInstances"][0]
    status = db["DBInstanceStatus"]
    source = db.get("ReadReplicaSourceDBInstanceIdentifier")

    if not source:
        message = (
            f"Replica {replica_id} has no replication source, it was already "
            f"promoted. No action taken. Trigger: {trigger}"
        )
        print(message)
        _notify(f"Failover skipped: {replica_id} already promoted", message)
        return {"action": "none", "reason": "already promoted"}

    if status != "available":
        message = (
            f"Replica {replica_id} is in status '{status}' and cannot be "
            f"promoted right now. Trigger: {trigger}"
        )
        print(message)
        _notify(f"Failover blocked: {replica_id} not promotable", message)
        return {"action": "none", "reason": f"replica status {status}"}

    rds.promote_read_replica(
        DBInstanceIdentifier=replica_id,
        BackupRetentionPeriod=1,
    )
    message = (
        f"Promotion of {replica_id} started. Route 53 has already shifted "
        f"traffic to the standby region via DNS failover. The database "
        f"becomes writable when promotion completes, typically within a few "
        f"minutes. Trigger: {trigger}"
    )
    print(message)
    _notify(f"Failover initiated: promoting {replica_id}", message)
    return {"action": "promote", "replica": replica_id, "trigger": trigger}
