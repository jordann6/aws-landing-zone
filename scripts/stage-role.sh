#!/usr/bin/env bash
#
# stage-role.sh: package the shared cis_baseline role at its pinned tag, plus the
# one collection it needs, and upload it to the prod artifacts bucket. The build
# instance has no internet path, so everything it installs comes from S3.

set -euo pipefail
# shellcheck source=scripts/lib-assume.sh
source "$(dirname "$0")/lib-assume.sh"

SOURCE="${HARDENING_REPO:-$ROOT/../azure-vm-hardening}"
RELEASE="$(workload_output cis_baseline_release)"
BUCKET="$(workload_output golden_image_artifacts_bucket)"
# community.general 9.x supports the ansible-core shipped in AL2023 (2.15).
COLLECTION="community.general:>=9.0.0,<10.0.0"

git -C "$SOURCE" rev-parse --verify --quiet "refs/tags/$RELEASE" >/dev/null || {
  echo "cis_baseline tag $RELEASE not found in $SOURCE (set HARDENING_REPO)"; exit 1; }

STAGE="$ROOT/.artifacts/cis-baseline-$RELEASE"
rm -rf "$STAGE" && mkdir -p "$STAGE"
git -C "$SOURCE" archive --prefix=bundle/ "$RELEASE" ansible scripts/check-hardening.sh | tar -x -C "$STAGE"
# python.org framework builds ship without a CA bundle; borrow certifi's from the
# interpreter ansible-galaxy runs on, when it has one.
GALAXY_PY="$(head -1 "$(command -v ansible-galaxy)" | sed 's/^#!//; s/ .*//')"
CA="$("$GALAXY_PY" -m certifi 2>/dev/null || true)"
SSL_CERT_FILE="${SSL_CERT_FILE:-$CA}" ansible-galaxy collection download "$COLLECTION" \
  -p "$STAGE/bundle/collections" >"$STAGE/galaxy.log" 2>&1 || { cat "$STAGE/galaxy.log"; exit 1; }
[[ -f "$STAGE/bundle/collections/requirements.yml" ]] || { cat "$STAGE/galaxy.log"; exit 1; }
tar -czf "$STAGE/bundle.tar.gz" -C "$STAGE" bundle
SHA="$(shasum -a 256 "$STAGE/bundle.tar.gz" | cut -d' ' -f1)"

assume "$(account_output prod_account_id)" stage-role
# The org require-s3-encryption SCP denies a PutObject without an explicit SSE
# header, whatever the bucket default; AES256 matches the bucket's SSE-S3.
aws s3 cp "$STAGE/bundle.tar.gz" "s3://$BUCKET/cis-baseline/$RELEASE/bundle.tar.gz" \
  --sse AES256 --metadata "sha256=$SHA,source-tag=$RELEASE" --only-show-errors
clear_creds
echo "Staged cis_baseline $RELEASE (sha256 $SHA) to s3://$BUCKET/cis-baseline/$RELEASE/"
