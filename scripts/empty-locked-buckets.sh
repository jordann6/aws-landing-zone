#!/usr/bin/env bash
#
# empty-locked-buckets.sh: empty the Object-Lock (GOVERNANCE) log buckets so the
# governance root can be destroyed. GOVERNANCE-mode retention blocks deletion, so
# each object version is deleted with an explicit BypassGovernanceRetention. This
# is the teardown trap the design calls out: a WORM bucket cannot be torn down by
# force_destroy alone.

export AWS_PAGER=""
set -uo pipefail

cd "$(dirname "$0")/../terraform" || exit 1

LOG_ARCHIVE_ID="$(terraform output -raw log_archive_account_id 2>/dev/null)" || {
  echo "empty-locked-buckets: no log_archive_account_id output; nothing to do."
  exit 0
}

creds="$(aws sts assume-role \
  --role-arn "arn:aws:iam::${LOG_ARCHIVE_ID}:role/OrganizationAccountAccessRole" \
  --role-session-name empty-buckets --query Credentials --output json)" || {
  echo "empty-locked-buckets: could not assume into log-archive account."
  exit 1
}
AWS_ACCESS_KEY_ID="$(echo "$creds" | python3 -c 'import sys,json;print(json.load(sys.stdin)["AccessKeyId"])')"
AWS_SECRET_ACCESS_KEY="$(echo "$creds" | python3 -c 'import sys,json;print(json.load(sys.stdin)["SecretAccessKey"])')"
AWS_SESSION_TOKEN="$(echo "$creds" | python3 -c 'import sys,json;print(json.load(sys.stdin)["SessionToken"])')"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

for bucket in "org-cloudtrail-logs-${LOG_ARCHIVE_ID}" "org-config-${LOG_ARCHIVE_ID}"; do
  if ! aws s3api head-bucket --bucket "$bucket" 2>/dev/null; then
    echo "  skip $bucket (absent)"
    continue
  fi
  echo "  emptying $bucket (bypassing GOVERNANCE retention)"
  versions="$(aws s3api list-object-versions --bucket "$bucket" \
    --query '{Objects: [].[Key, VersionId], Delete: DeleteMarkers[].[Key, VersionId]}' \
    --output json 2>/dev/null)"
  echo "$versions" | python3 - "$bucket" <<'PY'
import json, subprocess, sys
bucket = sys.argv[1]
data = json.load(sys.stdin)
items = (data.get("Objects") or []) + (data.get("Delete") or [])
for key, version in [i for i in items if i and i[0]]:
    subprocess.run([
        "aws", "s3api", "delete-object", "--bucket", bucket,
        "--key", key, "--version-id", version,
        "--bypass-governance-retention",
    ], check=False)
PY
done

echo "empty-locked-buckets: done."
