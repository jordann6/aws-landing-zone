"""Daily backup freshness check.

Finds the newest object in the backup bucket and publishes its age and the object
count as CloudWatch metrics. The alarm, not this function, decides what is stale,
and missing data alarms too, so a stopped check is not silent.
"""
import json
import os
from datetime import datetime, timezone

import boto3

BUCKET = os.environ["BUCKET_NAME"]
NAMESPACE = os.environ.get("METRIC_NAMESPACE", "BackupVerify")

s3 = boto3.client("s3")
cloudwatch = boto3.client("cloudwatch")


def newest_and_count(bucket):
    newest, count = None, 0
    for page in s3.get_paginator("list_objects_v2").paginate(Bucket=bucket):
        for obj in page.get("Contents", []):
            count += 1
            if newest is None or obj["LastModified"] > newest:
                newest = obj["LastModified"]
    return newest, count


def lambda_handler(event, context):
    newest, count = newest_and_count(BUCKET)
    now = datetime.now(timezone.utc)
    # An empty bucket reports a huge age so the alarm fires.
    age_hours = round((now - newest).total_seconds() / 3600, 1) if newest else 9999.0

    cloudwatch.put_metric_data(
        Namespace=NAMESPACE,
        MetricData=[
            {"MetricName": "NewestObjectAgeHours", "Value": age_hours, "Unit": "None",
             "Dimensions": [{"Name": "Bucket", "Value": BUCKET}]},
            {"MetricName": "ObjectCount", "Value": count, "Unit": "Count",
             "Dimensions": [{"Name": "Bucket", "Value": BUCKET}]},
        ],
    )
    result = {"bucket": BUCKET, "object_count": count, "newest_age_hours": age_hours}
    print(json.dumps(result))
    return result
