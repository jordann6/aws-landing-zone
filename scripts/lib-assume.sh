# shellcheck shell=bash
# Shared helpers: read the prod account from the persistent accounts state and
# assume OrganizationAccountAccessRole into it for the current shell.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export AWS_PAGER=""
export AWS_DEFAULT_REGION="${AWS_DEFAULT_REGION:-us-east-1}"

account_output() { terraform -chdir="$ROOT/accounts" output -raw "$1"; }
workload_output() { terraform -chdir="$ROOT/workload" output -raw "$1"; }

assume() {
  local creds
  creds="$(aws sts assume-role \
    --role-arn "arn:aws:iam::${1}:role/OrganizationAccountAccessRole" \
    --role-session-name "${2:-compute-baseline}" --query Credentials --output json)" || return 1
  AWS_ACCESS_KEY_ID="$(echo "$creds" | python3 -c 'import sys,json;print(json.load(sys.stdin)["AccessKeyId"])')"
  AWS_SECRET_ACCESS_KEY="$(echo "$creds" | python3 -c 'import sys,json;print(json.load(sys.stdin)["SecretAccessKey"])')"
  AWS_SESSION_TOKEN="$(echo "$creds" | python3 -c 'import sys,json;print(json.load(sys.stdin)["SessionToken"])')"
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
}
clear_creds() { unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN; }
