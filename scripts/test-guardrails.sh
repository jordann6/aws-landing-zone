#!/usr/bin/env bash
#
# test-guardrails.sh: prove the Phase 2 controls actually enforce, post-deploy.
# Complements validate.sh (which proves the SCP/OU structure) by exercising the
# logging, detective, and deny-disable guardrails against live accounts.

export AWS_PAGER=""
set -uo pipefail

cd "$(dirname "$0")/../accounts" || exit 1

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

DEV_ACCOUNT_ID="$(terraform output -raw dev_account_id)"
SECURITY_ACCOUNT_ID="$(terraform output -raw security_account_id)"

assume() {
  local creds
  creds="$(aws sts assume-role \
    --role-arn "arn:aws:iam::${1}:role/OrganizationAccountAccessRole" \
    --role-session-name guardrail-test --query Credentials --output json)" || return 1
  AWS_ACCESS_KEY_ID="$(echo "$creds" | python3 -c 'import sys,json;print(json.load(sys.stdin)["AccessKeyId"])')"
  AWS_SECRET_ACCESS_KEY="$(echo "$creds" | python3 -c 'import sys,json;print(json.load(sys.stdin)["SecretAccessKey"])')"
  AWS_SESSION_TOKEN="$(echo "$creds" | python3 -c 'import sys,json;print(json.load(sys.stdin)["SessionToken"])')"
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
}
clear_creds() { unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN; }

denied() { echo "$1" | grep -qE "AccessDenied|explicit deny|with an explicit deny"; }

echo "[1/4] Organization CloudTrail is logging..."
STATUS="$(aws cloudtrail get-trail-status --name org-trail --query IsLogging --output text 2>&1)"
[[ "$STATUS" == "True" ]] && pass "org-trail IsLogging=True" || fail "org-trail logging ($STATUS)"

echo "[2/4] GuardDuty delegated admin is the security account..."
ADMIN="$(aws guardduty list-organization-admin-accounts \
  --query 'AdminAccounts[0].AdminAccountId' --output text 2>&1)"
[[ "$ADMIN" == "$SECURITY_ACCOUNT_ID" ]] && pass "GuardDuty admin = security account" || fail "GuardDuty admin ($ADMIN)"

echo "[3/4] deny-disable-detective blocks turning Config off (dev account)..."
if assume "$DEV_ACCOUNT_ID"; then
  OUT="$(aws configservice stop-configuration-recorder \
    --configuration-recorder-name default 2>&1)"
  denied "$OUT" && pass "dev: StopConfigurationRecorder denied" || fail "dev: Config stop not denied ($OUT)"
  clear_creds
else
  fail "could not assume into dev account"
fi

echo "[4/4] deny-disable-detective blocks disabling GuardDuty (dev account)..."
if assume "$DEV_ACCOUNT_ID"; then
  OUT="$(aws guardduty delete-detector \
    --detector-id 00000000000000000000000000000000 2>&1)"
  denied "$OUT" && pass "dev: DeleteDetector denied" || fail "dev: GuardDuty delete not denied ($OUT)"
  clear_creds
else
  fail "could not assume into dev account"
fi

echo ""
echo "  Passed: $PASS   Failed: $FAIL"
[[ $FAIL -eq 0 ]]
