#!/bin/bash

export AWS_PAGER=""

set -euo pipefail

echo "------------------------------------------------"
echo "STARTING SCP GOVERNANCE VALIDATION"
echo "------------------------------------------------"

cd "$(dirname "$0")/../accounts"

MGMT_ACCOUNT_ID="$(terraform output -raw management_account_id)"
SANDBOX_ACCOUNT_ID="$(terraform output -raw sandbox_account_id)"
DEV_ACCOUNT_ID="$(terraform output -raw dev_account_id)"
PROD_ACCOUNT_ID="$(terraform output -raw prod_account_id)"
ORG_ID="$(terraform output -raw organization_id)"

echo "Using:"
echo "  MGMT_ACCOUNT    = $MGMT_ACCOUNT_ID"
echo "  SANDBOX_ACCOUNT  = $SANDBOX_ACCOUNT_ID"
echo "  DEV_ACCOUNT      = $DEV_ACCOUNT_ID"
echo "  PROD_ACCOUNT     = $PROD_ACCOUNT_ID"
echo "  ORGANIZATION     = $ORG_ID"

PASS=0
FAIL=0

check() {
  local label="$1" expected="$2" actual="$3"
  if [[ "$actual" == "$expected" ]]; then
    echo "  PASS: $label"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $label (expected=$expected, got=$actual)"
    FAIL=$((FAIL + 1))
  fi
}

assume_role() {
  local account_id="$1"
  local creds
  creds="$(aws sts assume-role \
    --role-arn "arn:aws:iam::${account_id}:role/OrganizationAccountAccessRole" \
    --role-session-name "scp-validation" \
    --query 'Credentials' \
    --output json)"

  export AWS_ACCESS_KEY_ID="$(echo "$creds" | python3 -c "import sys,json; print(json.load(sys.stdin)['AccessKeyId'])")"
  export AWS_SECRET_ACCESS_KEY="$(echo "$creds" | python3 -c "import sys,json; print(json.load(sys.stdin)['SecretAccessKey'])")"
  export AWS_SESSION_TOKEN="$(echo "$creds" | python3 -c "import sys,json; print(json.load(sys.stdin)['SessionToken'])")"
}

clear_role() {
  unset AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
}

# ============================================================
echo -e "\n[1/7] Verifying Organization Structure..."
# ============================================================

OU_COUNT="$(aws organizations list-organizational-units-for-parent \
  --parent-id "$(terraform output -raw organization_root_id)" \
  --query 'length(OrganizationalUnits)' --output text)"
check "Root has 6 top-level OUs (Security, Infrastructure, Sandbox, Workloads, Suspended, Deployments)" "6" "$OU_COUNT"

WORKLOADS_OU_ID="$(terraform output -raw workloads_ou_id)"
CHILD_COUNT="$(aws organizations list-organizational-units-for-parent \
  --parent-id "$WORKLOADS_OU_ID" \
  --query 'length(OrganizationalUnits)' --output text)"
check "Workloads OU has 3 child OUs (Dev, Test, Prod)" "3" "$CHILD_COUNT"

# ============================================================
echo -e "\n[2/7] Verifying SCP Attachments..."
# ============================================================

ROOT_ID="$(terraform output -raw organization_root_id)"
ROOT_POLICIES="$(aws organizations list-policies-for-target \
  --target-id "$ROOT_ID" --filter SERVICE_CONTROL_POLICY \
  --query 'Policies[].Name' --output text)"

echo "$ROOT_POLICIES" | grep -q "deny-leave-org" && \
  check "deny-leave-org attached at root" "true" "true" || \
  check "deny-leave-org attached at root" "true" "false"

echo "$ROOT_POLICIES" | grep -q "deny-root-user" && \
  check "deny-root-user attached at root" "true" "true" || \
  check "deny-root-user attached at root" "true" "false"

SANDBOX_OU_ID="$(terraform output -raw sandbox_ou_id)"
SANDBOX_POLICIES="$(aws organizations list-policies-for-target \
  --target-id "$SANDBOX_OU_ID" --filter SERVICE_CONTROL_POLICY \
  --query 'Policies[].Name' --output text)"

echo "$SANDBOX_POLICIES" | grep -q "region-lockdown" && \
  check "region-lockdown attached at Sandbox OU" "true" "true" || \
  check "region-lockdown attached at Sandbox OU" "true" "false"

echo "$ROOT_POLICIES" | grep -q "deny-disable-detective" && \
  check "deny-disable-detective (incl. CloudTrail tamper statement) attached at root" "true" "true" || \
  check "deny-disable-detective (incl. CloudTrail tamper statement) attached at root" "true" "false"

echo "$ROOT_POLICIES" | grep -q "deny-public-s3" && \
  check "deny-public-s3 attached at root" "true" "true" || \
  check "deny-public-s3 attached at root" "true" "false"

ROOT_SCP_COUNT="$(echo "$ROOT_POLICIES" | wc -w | tr -d ' ')"
check "Root holds at most 5 SCPs (AWS per-target limit)" "true" "$([ "$ROOT_SCP_COUNT" -le 5 ] && echo true || echo false)"

SECURITY_OU_ID="$(terraform output -raw security_ou_id)"
SECURITY_POLICIES="$(aws organizations list-policies-for-target \
  --target-id "$SECURITY_OU_ID" --filter SERVICE_CONTROL_POLICY \
  --query 'Policies[].Name' --output text)"

echo "$SECURITY_POLICIES" | grep -q "region-lockdown" && \
  check "region-lockdown attached at Security OU" "true" "true" || \
  check "region-lockdown attached at Security OU" "true" "false"

SUSPENDED_OU_ID="$(terraform output -raw suspended_ou_id)"
SUSPENDED_POLICIES="$(aws organizations list-policies-for-target \
  --target-id "$SUSPENDED_OU_ID" --filter SERVICE_CONTROL_POLICY \
  --query 'Policies[].Name' --output text)"

echo "$SUSPENDED_POLICIES" | grep -q "deny-all" && \
  check "deny-all attached at Suspended OU" "true" "true" || \
  check "deny-all attached at Suspended OU" "true" "false"

# ============================================================
echo -e "\n[3/7] Verifying Member Account Placement..."
# ============================================================

SANDBOX_PARENT="$(aws organizations list-parents \
  --child-id "$SANDBOX_ACCOUNT_ID" \
  --query 'Parents[0].Id' --output text)"
check "Sandbox account is in Sandbox OU" "$SANDBOX_OU_ID" "$SANDBOX_PARENT"

DEV_OU_ID="$(terraform output -raw dev_ou_id)"
DEV_PARENT="$(aws organizations list-parents \
  --child-id "$DEV_ACCOUNT_ID" \
  --query 'Parents[0].Id' --output text)"
check "Dev account is in Dev OU" "$DEV_OU_ID" "$DEV_PARENT"

PROD_PARENT="$(aws organizations list-parents \
  --child-id "$PROD_ACCOUNT_ID" \
  --query 'Parents[0].Id' --output text)"
check "Prod account is in Prod OU" "$PROD_OU_ID" "$PROD_PARENT"

# ============================================================
echo -e "\n[4/7] Testing Region Lockdown (Sandbox Account)..."
# ============================================================

assume_role "$SANDBOX_ACCOUNT_ID"

RESULT="$(aws sts get-caller-identity --region us-east-1 --query 'Account' --output text 2>&1)" && \
  check "Sandbox: us-east-1 STS call allowed" "$SANDBOX_ACCOUNT_ID" "$RESULT" || \
  check "Sandbox: us-east-1 STS call allowed" "allowed" "denied"

RESULT="$(aws sns list-topics --region us-west-2 2>&1)" && \
  check "Sandbox: us-west-2 SNS call denied" "denied" "allowed" || \
  { echo "$RESULT" | grep -q "AccessDenied\|AccessDeniedException\|AuthorizationError\|explicit deny" && \
    check "Sandbox: us-west-2 SNS call denied" "denied" "denied" || \
    check "Sandbox: us-west-2 SNS call denied" "denied" "error: $RESULT"; }

clear_role

# ============================================================
echo -e "\n[5/7] Testing Region Lockdown (Dev Account)..."
# ============================================================

assume_role "$DEV_ACCOUNT_ID"

RESULT="$(aws sns list-topics --region us-west-2 2>&1)" && \
  check "Dev: us-west-2 SNS call denied" "denied" "allowed" || \
  { echo "$RESULT" | grep -q "AccessDenied\|AccessDeniedException\|AuthorizationError\|explicit deny" && \
    check "Dev: us-west-2 SNS call denied" "denied" "denied" || \
    check "Dev: us-west-2 SNS call denied" "denied" "error: $RESULT"; }

RESULT="$(aws sts get-caller-identity --region us-east-1 --query 'Account' --output text 2>&1)" && \
  check "Dev: us-east-1 STS call allowed" "$DEV_ACCOUNT_ID" "$RESULT" || \
  check "Dev: us-east-1 STS call allowed" "allowed" "denied"

clear_role

# ============================================================
echo -e "\n[6/7] Testing CloudTrail Tampering + Public Access Block Deny (Dev Account)..."
# ============================================================
# This script runs as OrganizationAccountAccessRole, which is the break-glass
# exemption in both statements, so calling StopLogging here would prove nothing.
# The IAM policy simulator evaluates the SCPs for a NON-exempt principal (an
# Identity Center persona role in dev) without changing anything, and reports the
# Organizations layer separately from the role's own IAM policies.

assume_role "$DEV_ACCOUNT_ID"

PERSONA_ROLE="$(aws iam list-roles \
  --query "Roles[?starts_with(RoleName,'AWSReservedSSO_platform-eng_')].RoleName | [0]" --output text)"

for action in cloudtrail:StopLogging cloudtrail:DeleteTrail cloudtrail:UpdateTrail cloudtrail:PutEventSelectors s3:PutAccountPublicAccessBlock; do
  ORG_ALLOWED="$(aws iam simulate-principal-policy \
    --policy-source-arn "arn:aws:iam::${DEV_ACCOUNT_ID}:role/${PERSONA_ROLE}" \
    --action-names "$action" \
    --query 'EvaluationResults[0].OrganizationsDecisionDetail.AllowedByOrganizations' --output text 2>&1)"
  check "Dev persona: $action denied by SCP" "False" "$ORG_ALLOWED"
done

ORG_ALLOWED="$(aws iam simulate-principal-policy \
  --policy-source-arn "arn:aws:iam::${DEV_ACCOUNT_ID}:role/OrganizationAccountAccessRole" \
  --action-names cloudtrail:DeleteTrail \
  --query 'EvaluationResults[0].OrganizationsDecisionDetail.AllowedByOrganizations' --output text 2>&1)"
check "Dev break-glass role: cloudtrail:DeleteTrail exempt" "True" "$ORG_ALLOWED"

clear_role

# ============================================================
echo -e "\n[7/7] Testing Management Account SCP Exemption..."
# ============================================================

RESULT="$(aws s3api list-buckets --region us-west-2 --query 'length(Buckets)' --output text 2>&1)" && \
  check "Management account: us-west-2 call succeeds (SCP exempt)" "allowed" "allowed" || \
  check "Management account: us-west-2 call succeeds (SCP exempt)" "allowed" "denied"

# ============================================================
echo -e "\n------------------------------------------------"
echo "VALIDATION COMPLETE"
echo "  Passed: $PASS"
echo "  Failed: $FAIL"
echo "------------------------------------------------"

if [[ $FAIL -gt 0 ]]; then
  exit 1
fi
