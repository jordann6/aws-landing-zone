"""Rotation package: the psycopg2 port of the AWS template, and the load client.

Credential-free. Secrets Manager, RDS and PostgreSQL are stubbed; psycopg2 is the
real module so the exception classes the code catches are the real ones.
"""
import json
import os
import sys
from unittest import mock

import psycopg2
import pytest

sys.path.insert(0, os.path.join(os.path.dirname(os.path.abspath(__file__)), ".."))
os.environ.setdefault("AWS_DEFAULT_REGION", "us-east-1")

import lambda_function as rotation  # noqa: E402
import reporting_load as load  # noqa: E402

HOST = "prod-postgres.abc.us-east-1.rds.amazonaws.com"


def secret(username="orders_reporting", password="pw-1", **extra):
    value = {"engine": "postgres", "host": HOST, "port": 5432, "dbname": "orders",
             "username": username, "password": password, "masterarn": "arn:master", "ssl": True}
    value.update(extra)
    return value


def auth_failure(user="orders_reporting"):
    return psycopg2.OperationalError(f'FATAL:  password authentication failed for user "{user}"')


# ---- the port: connection layer only ----------------------------------------------

def test_connects_with_verify_full_against_the_packaged_rds_ca():
    with mock.patch.object(rotation.psycopg2, "connect") as connect:
        rotation.get_connection(secret())
    kwargs = connect.call_args.kwargs
    assert kwargs["sslmode"] == "verify-full"
    assert kwargs["sslrootcert"] == rotation.RDS_CA_BUNDLE
    assert kwargs["dbname"] == "orders"
    assert kwargs["user"] == "orders_reporting"


def test_ssl_true_never_falls_back_to_plaintext():
    with mock.patch.object(rotation.psycopg2, "connect", side_effect=auth_failure()) as connect:
        assert rotation.get_connection(secret()) is None
    assert connect.call_count == 1


def test_without_an_ssl_key_the_upstream_fallback_is_unchanged():
    value = secret()
    del value["ssl"]
    with mock.patch.object(rotation.psycopg2, "connect", side_effect=auth_failure()) as connect:
        assert rotation.get_connection(value) is None
    assert [c.kwargs["sslmode"] for c in connect.call_args_list] == ["verify-full", "disable"]


class FakeCursor:
    def __init__(self, existing_roles):
        self.existing_roles = existing_roles
        self.executed = []
        self._result = []

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False

    def execute(self, sql, params=None):
        self.executed.append((sql, params))
        if sql.startswith("SELECT quote_ident"):
            self._result = [(params[0],)]
        elif sql.startswith("SELECT 1 FROM pg_roles"):
            self._result = [(1,)] if params[0] in self.existing_roles else []

    def fetchone(self):
        return self._result[0]

    def fetchall(self):
        return self._result


def secrets_client(versions, master):
    client = mock.Mock()
    client.exceptions.ResourceNotFoundException = type("ResourceNotFoundException", (Exception,), {})

    def get_secret_value(SecretId, VersionStage, VersionId=None):
        if SecretId == "arn:master":
            return {"SecretString": json.dumps(master)}
        return {"SecretString": json.dumps(versions[VersionStage])}

    client.get_secret_value.side_effect = get_secret_value
    client.describe_secret.return_value = {
        "Tags": [{"Key": "aws:rds:primaryDBInstanceArn", "Value": "arn:aws:rds:us-east-1:1:db:prod-postgres"}]}
    return client


def test_first_rotation_creates_the_clone_from_the_rds_managed_master():
    # The RDS-managed master secret holds only username and password; the host comes
    # from DescribeDBInstances through the instance named in its system tag.
    current, pending = secret(), secret("orders_reporting_clone", "pw-2")
    client = secrets_client({"AWSCURRENT": current, "AWSPENDING": pending},
                            {"username": "appadmin", "password": "master-pw"})
    rds = mock.Mock()
    rds.describe_db_instances.return_value = {"DBInstances": [
        {"Endpoint": {"Address": HOST, "Port": 5432}, "Engine": "postgres"}]}
    cursor = FakeCursor(existing_roles={"orders_reporting"})
    master_conn = mock.Mock()
    master_conn.cursor.return_value = cursor

    def connect(**kwargs):
        if kwargs["user"] == "orders_reporting_clone":
            raise auth_failure("orders_reporting_clone")  # pending is not set yet
        return master_conn if kwargs["user"] == "appadmin" else mock.Mock()

    with mock.patch.object(rotation.psycopg2, "connect", side_effect=connect), \
            mock.patch.object(rotation.boto3, "client", return_value=rds):
        rotation.set_secret(client, "arn:reporting", "token")

    statements = [sql for sql, _ in cursor.executed]
    assert 'CREATE ROLE orders_reporting_clone WITH LOGIN PASSWORD %s' in statements
    assert ("GRANT orders_reporting TO orders_reporting_clone") in statements
    create = next(p for s, p in cursor.executed if s.startswith("CREATE ROLE"))
    assert create == ("pw-2",)
    master_conn.commit.assert_called_once()
    rds.describe_db_instances.assert_called_once_with(DBInstanceIdentifier="arn:aws:rds:us-east-1:1:db:prod-postgres")


# ---- the load client ---------------------------------------------------------------

class Clock:
    def __init__(self):
        self.now = 0.0

    def __call__(self):
        return self.now

    def sleep(self, seconds):
        self.now += max(seconds, 0.01)


def credentials(*values, cache_seconds=300, clock=None):
    client = mock.Mock()
    client.get_secret_value.side_effect = [
        {"SecretString": json.dumps(v), "VersionId": f"v{i}"} for i, v in enumerate(values, 1)]
    return client, load.Credentials(client, "arn:reporting", cache_seconds, clock or Clock())


def connection(user):
    conn = mock.MagicMock()
    conn.cursor.return_value.__enter__.return_value.fetchone.return_value = (user, 3)
    return conn


def test_secret_is_cached_until_it_goes_stale():
    clock = Clock()
    client, creds = credentials(secret(), secret("orders_reporting_clone"), clock=clock)
    creds.get()
    clock.now = 299
    creds.get()
    assert client.get_secret_value.call_count == 1
    clock.now = 300
    assert creds.get()[0]["username"] == "orders_reporting_clone"


def test_an_auth_failure_rereads_the_secret_and_retries_once():
    _, creds = credentials(secret(password="old"), secret("orders_reporting_clone", "new"))

    def connect(**kwargs):
        if kwargs["password"] == "old":
            raise auth_failure()
        return connection(kwargs["user"])

    record = load.one_query(creds, connect)
    assert record == {"user": "orders_reporting_clone", "version": "v2", "ok": True, "retried": True}


def test_a_second_auth_failure_counts_as_failed():
    _, creds = credentials(secret(), secret())
    record = load.one_query(creds, mock.Mock(side_effect=auth_failure()))
    assert record["ok"] is False and record["retried"] is True
    assert "password authentication failed" in record["error"]


def test_a_non_auth_error_fails_without_a_retry():
    client, creds = credentials(secret())
    record = load.one_query(creds, mock.Mock(side_effect=psycopg2.OperationalError("timeout expired")))
    assert record["ok"] is False and record["retried"] is False
    assert client.get_secret_value.call_count == 1


def test_queries_verify_tls_against_the_packaged_rds_ca():
    _, creds = credentials(secret())
    connect = mock.Mock(return_value=connection("orders_reporting"))
    load.one_query(creds, connect)
    assert connect.call_args.kwargs["sslmode"] == "verify-full"
    assert connect.call_args.kwargs["sslrootcert"] == load.RDS_CA_BUNDLE


def test_run_summarises_every_query(capsys):
    clock = Clock()
    _, creds = credentials(secret(), clock=clock)
    users = iter(["orders_reporting", "orders_reporting_clone"] * 10)
    summary = load.run(creds, lambda **kw: connection(next(users)), duration=1.9, rate=5,
                       clock=clock, sleep=clock.sleep, wall=clock)
    assert summary["queries"] == 10 and summary["ok"] == 10 and summary["failed"] == 0
    assert summary["users"] == ["orders_reporting", "orders_reporting_clone"]
    lines = [json.loads(line) for line in capsys.readouterr().out.splitlines()]
    assert len(lines) == 11 and lines[-1]["summary"] is True


@pytest.mark.parametrize("message, expected", [
    ('FATAL:  password authentication failed for user "x"', True),
    ("could not connect to server: timeout expired", False),
])
def test_auth_failure_detection(message, expected):
    assert load.is_auth_failure(psycopg2.OperationalError(message)) is expected
