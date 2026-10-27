"""Reporting client under rotation: the receipt for "zero failed connections".

Stands in for a BI tool that cannot use IAM database authentication. It behaves the
way a well-written password client does: it caches the secret, opens a fresh
connection per query, and on an authentication failure re-reads the secret once
before counting the query as failed. Every query is one bare JSON line on stdout
(no logger prefix, so CloudWatch JSON filters such as { $.ok IS FALSE } match);
the last line, also the return value, is the summary the proof reads.

Event (all optional): duration_seconds, rate_per_second, cache_seconds.
"""

import json
import os
import time

import boto3
import psycopg2

RDS_CA_BUNDLE = os.environ.get("RDS_CA_BUNDLE", "/var/task/rds-ca-bundle.pem")
QUERY = "SELECT current_user, count(*) FROM orders.orders"
# Leave headroom under the 900-second Lambda limit for the summary.
MAX_DURATION = 870


class Credentials:
    """The reporting secret, cached the way a client library would cache it."""

    def __init__(self, client, secret_id, cache_seconds, clock):
        self._client = client
        self._secret_id = secret_id
        self._cache_seconds = cache_seconds
        self._clock = clock
        self._value = None
        self._version = None
        self._fetched_at = None

    def get(self, refresh=False):
        stale = self._fetched_at is None or self._clock() - self._fetched_at >= self._cache_seconds
        if refresh or stale:
            response = self._client.get_secret_value(SecretId=self._secret_id)
            self._value = json.loads(response["SecretString"])
            self._version = response["VersionId"]
            self._fetched_at = self._clock()
        return self._value, self._version


def is_auth_failure(error):
    return "password authentication failed" in str(error)


def run_query(secret, connect):
    conn = connect(
        host=secret["host"],
        port=int(secret.get("port", 5432)),
        dbname=secret["dbname"],
        user=secret["username"],
        password=secret["password"],
        connect_timeout=5,
        sslmode="verify-full",
        sslrootcert=RDS_CA_BUNDLE,
    )
    try:
        with conn.cursor() as cur:
            cur.execute(QUERY)
            return cur.fetchone()[0]
    finally:
        conn.close()


def one_query(credentials, connect):
    """Run one query, retrying once with a re-read secret on an auth failure."""
    secret, version = credentials.get()
    record = {"user": secret["username"], "version": version, "ok": True, "retried": False}
    try:
        record["user"] = run_query(secret, connect)
        return record
    except psycopg2.OperationalError as error:
        if not is_auth_failure(error):
            record.update(ok=False, error=str(error).strip())
            return record
    secret, version = credentials.get(refresh=True)
    record.update(version=version, retried=True)
    try:
        record["user"] = run_query(secret, connect)
    except psycopg2.OperationalError as error:
        record.update(ok=False, error=str(error).strip())
    return record


def run(credentials, connect, duration, rate, clock=time.monotonic, sleep=time.sleep, wall=time.time):
    summary = {"summary": True, "queries": 0, "ok": 0, "failed": 0, "retried": 0, "users": set(), "versions": set()}
    interval = 1.0 / rate
    deadline = clock() + duration
    while clock() < deadline:
        started = clock()
        record = one_query(credentials, connect)
        record["t"] = round(wall(), 3)
        print(json.dumps(record), flush=True)
        summary["queries"] += 1
        summary["ok" if record["ok"] else "failed"] += 1
        summary["retried"] += record["retried"]
        summary["users"].add(record["user"])
        summary["versions"].add(record["version"])
        sleep(max(0.0, interval - (clock() - started)))
    summary["users"] = sorted(summary["users"])
    summary["versions"] = sorted(summary["versions"])
    print(json.dumps(summary), flush=True)
    return summary


def lambda_handler(event, context):
    duration = min(int(event.get("duration_seconds", 840)), MAX_DURATION)
    rate = float(event.get("rate_per_second", 5))
    cache_seconds = int(event.get("cache_seconds", 300))
    credentials = Credentials(boto3.client("secretsmanager"), os.environ["SECRET_ARN"], cache_seconds, time.monotonic)
    return run(credentials, psycopg2.connect, duration, rate)
