#!/usr/bin/env bash
#
# test-guardrails.sh: prove the Phase 2 controls actually enforce, post-deploy.
# Complements validate.sh (which proves the SCP/OU structure) by exercising the
# logging, detective, and deny-disable guardrails against live accounts, then the
# compute baseline (sandbox-first SCPs + EC2 declarative policy) with EC2
# --dry-run calls, which are free and are evaluated against both.

export AWS_PAGER=""
set -uo pipefail

cd "$(dirname "$0")/../accounts" || exit 1

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

DEV_ACCOUNT_ID="$(terraform output -raw dev_account_id)"
SANDBOX_ACCOUNT_ID="$(terraform output -raw sandbox_account_id)"
SANDBOX_OU_ID="$(terraform output -raw sandbox_ou_id)"
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

echo "[1/9] Organization CloudTrail is logging..."
STATUS="$(aws cloudtrail get-trail-status --name org-trail --query IsLogging --output text 2>&1)"
[[ "$STATUS" == "True" ]] && pass "org-trail IsLogging=True" || fail "org-trail logging ($STATUS)"

echo "[2/9] GuardDuty delegated admin is the security account..."
ADMIN="$(aws guardduty list-organization-admin-accounts \
  --query 'AdminAccounts[0].AdminAccountId' --output text 2>&1)"
[[ "$ADMIN" == "$SECURITY_ACCOUNT_ID" ]] && pass "GuardDuty admin = security account" || fail "GuardDuty admin ($ADMIN)"

echo "[3/9] deny-disable-detective blocks turning Config off (dev account)..."
if assume "$DEV_ACCOUNT_ID"; then
  OUT="$(aws configservice stop-configuration-recorder \
    --configuration-recorder-name default 2>&1)"
  denied "$OUT" && pass "dev: StopConfigurationRecorder denied" || fail "dev: Config stop not denied ($OUT)"
  clear_creds
else
  fail "could not assume into dev account"
fi

echo "[4/9] deny-disable-detective blocks disabling GuardDuty (dev account)..."
if assume "$DEV_ACCOUNT_ID"; then
  OUT="$(aws guardduty delete-detector \
    --detector-id 00000000000000000000000000000000 2>&1)"
  denied "$OUT" && pass "dev: DeleteDetector denied" || fail "dev: GuardDuty delete not denied ($OUT)"
  clear_creds
else
  fail "could not assume into dev account"
fi

# ---- compute baseline (sandbox OU) --------------------------------------------
skip() { echo "  SKIP: $1"; }
# A dry run that passes authorization fails with DryRunOperation; one that is
# denied by an SCP or the declarative policy fails with UnauthorizedOperation (or
# the declarative policy's exception message).
dry_denied() { echo "$1" | grep -qE "UnauthorizedOperation|not allowed|Sandbox compute baseline policy denied"; }
dry_allowed() { echo "$1" | grep -q "DryRunOperation"; }

ATTACHED="$(aws organizations list-policies-for-target --target-id "$SANDBOX_OU_ID" \
  --filter DECLARATIVE_POLICY_EC2 --query "Policies[?Name=='sandbox-ec2-baseline'] | length(@)" --output text 2>&1)"
if [[ "$ATTACHED" != "1" ]]; then
  for n in 5 6 7 8 9; do echo "[$n/9] compute baseline"; skip "sandbox-ec2-baseline not attached; apply the accounts plan first"; done
else
  AL2023="$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
    --query Parameter.Value --output text)"
  UBUNTU="$(aws ssm get-parameter --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
    --query Parameter.Value --output text)"
  if assume "$SANDBOX_ACCOUNT_ID"; then
    echo "[5/9] Declarative policy is in effect in the sandbox account..."
    STATE="$(aws ec2 get-allowed-images-settings --query State --output text 2>&1)"
    [[ "$STATE" == "enabled" ]] && pass "sandbox: Allowed AMIs enabled" || fail "sandbox: Allowed AMIs ($STATE)"
    TOKENS="$(aws ec2 get-instance-metadata-defaults --query AccountLevel.HttpTokens --output text 2>&1)"
    [[ "$TOKENS" == "required" ]] && pass "sandbox: IMDSv2 required by default" || fail "sandbox: IMDS default ($TOKENS)"

    echo "[6/9] IMDSv1 launch is denied..."
    OUT="$(aws ec2 run-instances --dry-run --image-id "$AL2023" --instance-type t3.micro \
      --metadata-options HttpTokens=optional 2>&1)"
    dry_denied "$OUT" && pass "sandbox: HttpTokens=optional denied" || fail "sandbox: IMDSv1 launch not denied ($OUT)"

    echo "[7/9] Launch from a non-allowed AMI (Canonical Ubuntu) is denied..."
    OUT="$(aws ec2 run-instances --dry-run --image-id "$UBUNTU" --instance-type t3.micro \
      --metadata-options HttpTokens=required 2>&1)"
    dry_denied "$OUT" && pass "sandbox: non-allowed AMI denied" || fail "sandbox: non-allowed AMI not denied ($OUT)"

    echo "[8/9] Unencrypted volume is denied..."
    OUT="$(aws ec2 create-volume --dry-run --size 1 --volume-type gp3 --no-encrypted \
      --availability-zone us-east-1a 2>&1)"
    dry_denied "$OUT" && pass "sandbox: unencrypted CreateVolume denied" || fail "sandbox: unencrypted volume not denied ($OUT)"

    echo "[9/9] A compliant launch is still allowed (control, not a blanket deny)..."
    OUT="$(aws ec2 run-instances --dry-run --image-id "$AL2023" --instance-type t3.micro \
      --metadata-options HttpTokens=required \
      --block-device-mappings 'DeviceName=/dev/xvda,Ebs={Encrypted=true,VolumeType=gp3}' 2>&1)"
    if dry_allowed "$OUT"; then
      pass "sandbox: compliant launch reaches DryRunOperation"
    elif echo "$OUT" | grep -qE "VPCIdNotSpecified|MissingInput"; then
      skip "sandbox has no default VPC, so the compliant dry run cannot resolve a subnet ($OUT)"
    else
      fail "sandbox: compliant launch denied ($OUT)"
    fi
    clear_creds
  else
    fail "could not assume into sandbox account"
  fi
fi

echo ""
echo "  Passed: $PASS   Failed: $FAIL"
[[ $FAIL -eq 0 ]]
