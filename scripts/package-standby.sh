#!/usr/bin/env bash
# Package the app API Lambda into build/api. Run before terraform plan.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../standby" && pwd)"
BUILD="$ROOT/build/api"

rm -rf "$BUILD"
mkdir -p "$BUILD"

echo "Installing dependencies..."
python3 -m pip install --quiet --target "$BUILD" -r "$ROOT/app/api/requirements.txt"

echo "Copying handler..."
cp "$ROOT/app/api/handler.py" "$BUILD/"

echo "Fetching the RDS CA bundle so the app verifies TLS to PostgreSQL..."
curl -sSf -o "$BUILD/rds-ca-bundle.pem" \
  "https://truststore.pki.rds.amazonaws.com/global/global-bundle.pem"

echo "Packaged app/api into build/api"
