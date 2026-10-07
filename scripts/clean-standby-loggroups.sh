#!/usr/bin/env bash
#
# clean-standby-loggroups.sh: after `terraform destroy` in standby/, list and delete
# empty log groups the destroy left behind (Lambda recreates its group on a late
# invoke). Fail closed: verifies the prod account before deleting anything, and
# only touches groups whose name contains lz-standby. Run with bash, not source.

export AWS_PAGER=""
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PROD_ID="$(terraform -chdir="$ROOT/accounts" output -raw prod_account_id)" || exit 1
[[ -n "$PROD_ID" ]] || exit 1
creds="$(aws sts assume-role --role-arn "arn:aws:iam::${PROD_ID}:role/OrganizationAccountAccessRole" \
  --role-session-name standby-clean --query Credentials --output json)" || exit 1
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
AWS_ACCESS_KEY_ID="$(echo "$creds" | python3 -c 'import sys,json;print(json.load(sys.stdin)["AccessKeyId"])')"
AWS_SECRET_ACCESS_KEY="$(echo "$creds" | python3 -c 'import sys,json;print(json.load(sys.stdin)["SecretAccessKey"])')"
AWS_SESSION_TOKEN="$(echo "$creds" | python3 -c 'import sys,json;print(json.load(sys.stdin)["SessionToken"])')"
[[ "$(aws sts get-caller-identity --query Account --output text)" == "$PROD_ID" ]] || { echo "wrong account"; exit 1; }
for region in us-east-1 us-west-2; do
  for g in $(aws logs describe-log-groups --region "$region" \
      --query 'logGroups[?contains(logGroupName, `lz-standby`)].logGroupName' --output text); do
    echo "deleting $region $g"
    aws logs delete-log-group --region "$region" --log-group-name "$g"
  done
done
echo "done"
