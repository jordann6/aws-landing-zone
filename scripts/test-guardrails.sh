#!/usr/bin/env bash
#
# test-guardrails.sh: prove the Phase 2 controls actually enforce, post-deploy.
# Complements validate.sh (which proves the SCP/OU structure) by exercising the
# logging, detective, and deny-disable guardrails against live accounts, then the
# compute baseline (SCPs + EC2 declarative policies on the Sandbox and Workloads
# OUs, the latter proven in prod) with EC2 --dry-run calls, which are free and are evaluated against both.

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
PROD_ACCOUNT_ID="$(terraform output -raw prod_account_id)"
WORKLOADS_OU_ID="$(terraform output -raw workloads_ou_id)"
# Matches workload/variables.tf eks_version; the node AMI parameter is per minor.
EKS_VERSION="${EKS_VERSION:-1.35}"
TOTAL=15

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

echo "[1/$TOTAL] Organization CloudTrail is logging..."
STATUS="$(aws cloudtrail get-trail-status --name org-trail --query IsLogging --output text 2>&1)"
[[ "$STATUS" == "True" ]] && pass "org-trail IsLogging=True" || fail "org-trail logging ($STATUS)"

echo "[2/$TOTAL] GuardDuty delegated admin is the security account..."
ADMIN="$(aws guardduty list-organization-admin-accounts \
  --query 'AdminAccounts[0].AdminAccountId' --output text 2>&1)"
[[ "$ADMIN" == "$SECURITY_ACCOUNT_ID" ]] && pass "GuardDuty admin = security account" || fail "GuardDuty admin ($ADMIN)"

echo "[3/$TOTAL] deny-disable-detective blocks turning Config off (dev account)..."
if assume "$DEV_ACCOUNT_ID"; then
  OUT="$(aws configservice stop-configuration-recorder \
    --configuration-recorder-name default 2>&1)"
  denied "$OUT" && pass "dev: StopConfigurationRecorder denied" || fail "dev: Config stop not denied ($OUT)"
  clear_creds
else
  fail "could not assume into dev account"
fi

echo "[4/$TOTAL] deny-disable-detective blocks disabling GuardDuty (dev account)..."
if assume "$DEV_ACCOUNT_ID"; then
  OUT="$(aws guardduty delete-detector \
    --detector-id 00000000000000000000000000000000 2>&1)"
  denied "$OUT" && pass "dev: DeleteDetector denied" || fail "dev: GuardDuty delete not denied ($OUT)"
  clear_creds
else
  fail "could not assume into dev account"
fi

# ---- compute baseline (Sandbox OU, then Workloads OU via prod) ---------------
skip() { echo "  SKIP: $1"; }
# A dry run that passes authorization fails with DryRunOperation. Each denial
# below matches the exact text its layer returns (verified live 2026-10-06).
dry_allowed() { echo "$1" | grep -q "DryRunOperation"; }

AL2023="$(aws ssm get-parameter --name /aws/service/ami-amazon-linux-latest/al2023-ami-kernel-default-x86_64 \
  --query Parameter.Value --output text)"
UBUNTU="$(aws ssm get-parameter --name /aws/service/canonical/ubuntu/server/24.04/stable/current/amd64/hvm/ebs-gp3/ami-id \
  --query Parameter.Value --output text)"
# Control for the non-allowed AMI sections: the Ubuntu AMI must exist (seen from
# the management account, which has no Allowed AMIs policy). Otherwise a deleted
# image would pass as "denied".
UBUNTU_STATE="$(aws ec2 describe-images --image-ids "$UBUNTU" --query 'Images[0].State' --output text 2>&1)"

# ec2_baseline_checks LABEL ACCOUNT_ID OU_ID POLICY_NAME FIRST_SECTION
# Five sections: policy in effect, IMDSv1 denied, non-allowed AMI hidden,
# unencrypted volume denied, compliant launch allowed.
ec2_baseline_checks() {
  local label="$1" account="$2" ou="$3" policy="$4" n="$5" attached out state tokens hops
  attached="$(aws organizations list-policies-for-target --target-id "$ou" \
    --filter DECLARATIVE_POLICY_EC2 --query "Policies[?Name=='$policy'] | length(@)" --output text 2>&1)"
  if [[ "$attached" != "1" ]]; then
    for i in 0 1 2 3 4; do echo "[$((n + i))/$TOTAL] compute baseline ($label)"; skip "$policy not attached; apply the accounts plan first"; done
    return
  fi
  if ! assume "$account"; then
    fail "could not assume into $label account"
    return
  fi

  echo "[$n/$TOTAL] Declarative policy $policy is in effect in $label..."
  state="$(aws ec2 get-allowed-images-settings --query State --output text 2>&1)"
  [[ "$state" == "enabled" ]] && pass "$label: Allowed AMIs enabled" || fail "$label: Allowed AMIs ($state)"
  tokens="$(aws ec2 get-instance-metadata-defaults --query AccountLevel.HttpTokens --output text 2>&1)"
  [[ "$tokens" == "required" ]] && pass "$label: IMDSv2 required by default" || fail "$label: IMDS default ($tokens)"
  hops="$(aws ec2 get-instance-metadata-defaults --query AccountLevel.HttpPutResponseHopLimit --output text 2>&1)"
  [[ "$hops" == "1" ]] && pass "$label: IMDS hop limit 1 by default" || fail "$label: IMDS hop limit ($hops)"

  echo "[$((n + 1))/$TOTAL] IMDSv1 launch is denied in $label..."
  out="$(aws ec2 run-instances --dry-run --image-id "$AL2023" --instance-type t3.micro \
    --metadata-options HttpTokens=optional 2>&1)"
  # The declarative policy's httpTokensEnforced rejects this before the SCP is
  # evaluated, so the real denial is UnsupportedOperation with this text.
  if grep -qF "You can't launch instances with IMDSv1 because httpTokensEnforced is enabled" <<<"$out"; then
    pass "$label: HttpTokens=optional denied (httpTokensEnforced)"
  else
    fail "$label: IMDSv1 launch not denied ($out)"
  fi

  echo "[$((n + 2))/$TOTAL] Launch from a non-allowed AMI (Canonical Ubuntu) is denied in $label..."
  out="$(aws ec2 run-instances --dry-run --image-id "$UBUNTU" --instance-type t3.micro \
    --metadata-options HttpTokens=required 2>&1)"
  # Allowed AMIs hides non-allowed images from the account, so EC2 reports the
  # existing image as not found. Pass only if the management account sees it.
  if [[ "$UBUNTU_STATE" != "available" ]]; then
    fail "$label: control failed, Ubuntu AMI $UBUNTU is '$UBUNTU_STATE' from the management account"
  elif grep -qF "InvalidAMIID.NotFound" <<<"$out" && grep -qF "The image id '[$UBUNTU]' does not exist" <<<"$out"; then
    pass "$label: non-allowed AMI hidden and denied (exists outside $label, NotFound inside)"
  else
    fail "$label: non-allowed AMI not denied ($out)"
  fi

  echo "[$((n + 3))/$TOTAL] Unencrypted volume is denied in $label..."
  out="$(aws ec2 create-volume --dry-run --size 1 --volume-type gp3 --no-encrypted \
    --availability-zone us-east-1a 2>&1)"
  if grep -qF "with an explicit deny in a service control policy" <<<"$out"; then
    pass "$label: unencrypted CreateVolume denied (SCP require-encrypted-ebs)"
  else
    fail "$label: unencrypted volume not denied ($out)"
  fi

  echo "[$((n + 4))/$TOTAL] A compliant launch is still allowed in $label (control, not a blanket deny)..."
  out="$(aws ec2 run-instances --dry-run --image-id "$AL2023" --instance-type t3.micro \
    --metadata-options HttpTokens=required \
    --block-device-mappings 'DeviceName=/dev/xvda,Ebs={Encrypted=true,VolumeType=gp3}' 2>&1)"
  if dry_allowed "$out"; then
    pass "$label: compliant launch reaches DryRunOperation"
  elif echo "$out" | grep -qE "VPCIdNotSpecified|MissingInput"; then
    skip "$label has no default VPC, so the compliant dry run cannot resolve a subnet ($out)"
  else
    fail "$label: compliant launch denied ($out)"
  fi
  clear_creds
}

ec2_baseline_checks sandbox "$SANDBOX_ACCOUNT_ID" "$SANDBOX_OU_ID" sandbox-ec2-baseline 5
ec2_baseline_checks prod "$PROD_ACCOUNT_ID" "$WORKLOADS_OU_ID" workloads-ec2-baseline 10

echo "[15/$TOTAL] Workloads OU: both compute SCPs attached, EKS node AMI allowed in prod..."
SCPS="$(aws organizations list-policies-for-target --target-id "$WORKLOADS_OU_ID" \
  --filter SERVICE_CONTROL_POLICY \
  --query "length(Policies[?Name=='require-imdsv2' || Name=='require-encrypted-ebs'])" --output text 2>&1)"
[[ "$SCPS" == "2" ]] && pass "Workloads OU: require-imdsv2 + require-encrypted-ebs attached" || fail "Workloads OU SCPs ($SCPS)"
# The managed node group launches the EKS-optimized AL2023 image, which Amazon
# publishes under a name the AL2023 criterion does not match. It must stay
# visible and allowed, or the node group cannot scale.
EKS_AMI="$(aws ssm get-parameter --name "/aws/service/eks/optimized-ami/${EKS_VERSION}/amazon-linux-2023/x86_64/standard/recommended/image_id" \
  --query Parameter.Value --output text 2>&1)"
if assume "$PROD_ACCOUNT_ID"; then
  ALLOWED="$(aws ec2 describe-images --image-ids "$EKS_AMI" --query 'Images[0].ImageAllowed' --output text 2>&1)"
  [[ "$ALLOWED" == "True" ]] && pass "prod: EKS ${EKS_VERSION} node AMI $EKS_AMI ImageAllowed=True" || fail "prod: EKS node AMI $EKS_AMI ($ALLOWED)"
  clear_creds
else
  fail "could not assume into prod account"
fi

echo ""
echo "  Passed: $PASS   Failed: $FAIL"
[[ $FAIL -eq 0 ]]
