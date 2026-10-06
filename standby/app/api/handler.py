"""Regional order API.

Runs identically in both regions. The region role only changes behavior
indirectly: against the read replica, writes fail with a clear 409 until the
failover manager promotes it.
"""

import json
import os
import ssl

import boto3
import pg8000.exceptions
import pg8000.native

_CA_BUNDLE = os.path.join(os.path.dirname(__file__), "rds-ca-bundle.pem")

_secret_cache = None
_conn = None


def _get_credentials():
    global _secret_cache
    if _secret_cache is None:
        client = boto3.client("secretsmanager")
        raw = client.get_secret_value(SecretId=os.environ["SECRET_ARN"])
        _secret_cache = json.loads(raw["SecretString"])
    return _secret_cache


def _connect():
    creds = _get_credentials()
    ssl_context = ssl.create_default_context(cafile=_CA_BUNDLE)
    return pg8000.native.Connection(
        user=creds["username"],
        password=creds["password"],
        host=os.environ["DB_HOST"],
        port=int(os.environ.get("DB_PORT", "5432")),
        database=os.environ["DB_NAME"],
        ssl_context=ssl_context,
        timeout=5,
    )


def _get_connection():
    global _conn
    if _conn is None:
        _conn = _connect()
    return _conn


def _run(sql, **params):
    """Run a statement, reconnecting once if the cached connection died."""
    global _conn
    try:
        return _get_connection().run(sql, **params)
    except (pg8000.exceptions.InterfaceError, BrokenPipeError, OSError):
        _conn = _connect()
        return _conn.run(sql, **params)


def _ensure_table():
    _run(
        """
        CREATE TABLE IF NOT EXISTS orders (
            id SERIAL PRIMARY KEY,
            item TEXT NOT NULL,
            quantity INTEGER NOT NULL DEFAULT 1,
            created_at TIMESTAMPTZ NOT NULL DEFAULT now()
        )
        """
    )


def _response(status, body):
    return {
        "statusCode": status,
        "headers": {"content-type": "application/json"},
        "body": json.dumps(body, default=str),
    }


def _region_info():
    return {
        "region": os.environ.get("AWS_REGION", "unknown"),
        "role": os.environ.get("REGION_ROLE", "unknown"),
    }


def _is_read_only_error(exc):
    # SQLSTATE 25006: cannot execute ... in a read-only transaction
    args = getattr(exc, "args", [])
    return args and isinstance(args[0], dict) and args[0].get("C") == "25006"


def _health():
    if os.environ.get("SIMULATE_FAILURE", "false").lower() == "true":
        return _response(
            500, {"status": "unhealthy", "simulated": True, **_region_info()}
        )
    try:
        _run("SELECT 1")
    except Exception as exc:  # noqa: BLE001 - report any DB failure as unhealthy
        return _response(
            500, {"status": "unhealthy", "error": str(exc), **_region_info()}
        )
    return _response(200, {"status": "healthy", **_region_info()})


def _list_orders():
    try:
        _ensure_table()
    except pg8000.exceptions.DatabaseError as exc:
        # A replica cannot create the table, the primary already did.
        if not _is_read_only_error(exc):
            raise
    rows = _run(
        "SELECT id, item, quantity, created_at FROM orders ORDER BY id DESC LIMIT 20"
    )
    orders = [
        {"id": r[0], "item": r[1], "quantity": r[2], "created_at": r[3]}
        for r in rows or []
    ]
    return _response(200, {"orders": orders, "count": len(orders), **_region_info()})


def _create_order(body):
    try:
        payload = json.loads(body or "{}")
    except json.JSONDecodeError:
        return _response(400, {"error": "body must be JSON"})

    item = payload.get("item")
    if not item:
        return _response(400, {"error": "field 'item' is required"})
    quantity = int(payload.get("quantity", 1))

    try:
        _ensure_table()
        rows = _run(
            "INSERT INTO orders (item, quantity) VALUES (:item, :quantity) RETURNING id",
            item=item,
            quantity=quantity,
        )
    except pg8000.exceptions.DatabaseError as exc:
        if _is_read_only_error(exc):
            return _response(
                409,
                {
                    "error": "this region is serving a read-only replica, "
                    "writes resume after failover promotion",
                    **_region_info(),
                },
            )
        raise
    return _response(
        201, {"id": rows[0][0], "item": item, "quantity": quantity, **_region_info()}
    )


def lambda_handler(event, _context):
    method = event.get("requestContext", {}).get("http", {}).get("method", "GET")
    path = event.get("rawPath", "/")

    try:
        if path == "/health" and method == "GET":
            return _health()
        if path == "/orders" and method == "GET":
            return _list_orders()
        if path == "/orders" and method == "POST":
            return _create_order(event.get("body"))
        return _response(404, {"error": f"no route for {method} {path}"})
    except Exception as exc:  # noqa: BLE001 - surface unexpected errors as 500s
        return _response(500, {"error": str(exc), **_region_info()})
