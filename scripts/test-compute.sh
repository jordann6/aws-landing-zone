#!/usr/bin/env bash
#
# test-compute.sh: prove on the live management instance that the compute
# baseline landed, not just that apply succeeded.
#   1. Account defaults in prod: EBS encryption on with the CMK, IMDSv2 default.
#   2. The instance: golden AMI, no public IP, no SSH key, IMDSv2 at hop 1,
#      CMK-encrypted root, no inbound rules, patch group tag.
#   3. SSM: online through the private endpoints, Default Host Management set.
#   4. Guest: the cis_baseline role's own check-hardening.sh, fetched from the
#      pinned tag in the source repo (not the copy baked into the image), run
#      through SSM Run Command. Same script as the Azure and GCP proofs.
#   5. Patching: the instance reports patch compliance to the prod baseline.

set -uo pipefail
# shellcheck source=scripts/lib-assume.sh
source "$(dirname "$0")/lib-assume.sh"

PASS=0
FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
expect() { [[ "$2" == "$3" ]] && pass "$1" || fail "$1 (expected $2, got $3)"; }

SOURCE="${HARDENING_REPO:-$ROOT/../azure-vm-hardening}"
RELEASE="$(workload_output cis_baseline_release)"
KMS_KEY="$(workload_output ebs_kms_key_arn)"
INSTANCE="$(terraform -chdir="$ROOT/compute" output -json management_instance \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["id"])')"
CHECK_SCRIPT="$(git -C "$SOURCE" show "$RELEASE:scripts/check-hardening.sh")" || {
  echo "cannot read check-hardening.sh at $RELEASE from $SOURCE (set HARDENING_REPO)"; exit 1; }

assume "$(account_output prod_account_id)" test-compute || { echo "could not assume into prod"; exit 1; }

echo "[1/5] Prod account EC2 defaults..."
expect "EBS encryption by default" "True" \
  "$(aws ec2 get-ebs-encryption-by-default --query EbsEncryptionByDefault --output text)"
expect "default EBS key is the prod CMK" "$KMS_KEY" \
  "$(aws ec2 get-ebs-default-kms-key-id --query KmsKeyId --output text)"
expect "account IMDS default HttpTokens" "required" \
  "$(aws ec2 get-instance-metadata-defaults --query AccountLevel.HttpTokens --output text)"

echo "[2/5] Management instance posture..."
q() { aws ec2 describe-instances --instance-ids "$INSTANCE" --query "Reservations[0].Instances[0].$1" --output text; }
AMI="$(q ImageId)"
expect "boots from a golden AMI" "true" \
  "$(aws ec2 describe-images --image-ids "$AMI" --query "Images[0].Tags[?Key=='GoldenImage'].Value | [0]" --output text)"
expect "golden AMI carries the pinned role tag" "$RELEASE" \
  "$(aws ec2 describe-images --image-ids "$AMI" --query "Images[0].Tags[?Key=='CisBaseline'].Value | [0]" --output text)"
expect "no public IP" "None" "$(q PublicIpAddress)"
expect "no SSH key pair" "None" "$(q KeyName)"
expect "IMDSv2 required" "required" "$(q MetadataOptions.HttpTokens)"
expect "IMDS hop limit 1" "1" "$(q MetadataOptions.HttpPutResponseHopLimit)"
expect "Patch Group tag" "prod" "$(q "Tags[?Key=='Patch Group'].Value | [0]")"
VOL="$(q 'BlockDeviceMappings[0].Ebs.VolumeId')"
expect "root volume encrypted" "True" "$(aws ec2 describe-volumes --volume-ids "$VOL" --query 'Volumes[0].Encrypted' --output text)"
expect "root volume uses the prod CMK" "$KMS_KEY" "$(aws ec2 describe-volumes --volume-ids "$VOL" --query 'Volumes[0].KmsKeyId' --output text)"
# shellcheck disable=SC2046 # split on purpose: one id per attached group
INGRESS="$(aws ec2 describe-security-groups --group-ids $(q 'SecurityGroups[].GroupId') \
  --query 'length(SecurityGroups[].IpPermissions[])' --output text)"
expect "security groups allow no inbound" "0" "$INGRESS"

echo "[3/5] SSM reachability (private endpoints only)..."
DHMC="$(aws ssm get-service-setting --setting-id /ssm/managed-instance/default-ec2-instance-management-role \
  --query ServiceSetting.SettingValue --output text)"
expect "Default Host Management role set" "prod-ssm-default-host-management" "$DHMC"
PING="None"
for _ in $(seq 1 20); do
  PING="$(aws ssm describe-instance-information --filters "Key=InstanceIds,Values=$INSTANCE" \
    --query 'InstanceInformationList[0].PingStatus' --output text)"
  [[ "$PING" == "Online" ]] && break
  sleep 15
done
expect "SSM agent Online" "Online" "$PING"

echo "[4/5] Guest hardening (check-hardening.sh at $RELEASE via Run Command)..."
# Written to a root-only temp file and run under bash explicitly, whatever shell
# Run Command uses to wrap the document.
PARAMS="$(CHECK_SCRIPT="$CHECK_SCRIPT" python3 -c '
import os, json
body = os.environ["CHECK_SCRIPT"].splitlines()
cmds = ["umask 077", "cat > /root/lz-check.sh <<'"'"'LZ_CHECK_EOF'"'"'"] + body + ["LZ_CHECK_EOF", "bash /root/lz-check.sh; rc=$?; rm -f /root/lz-check.sh; exit $rc"]
print(json.dumps({"commands": cmds}))')"
CMD="$(aws ssm send-command --instance-ids "$INSTANCE" --document-name AWS-RunShellScript \
  --comment "compute baseline proof $RELEASE" --parameters "$PARAMS" --query Command.CommandId --output text)"
STATUS="Pending"
for _ in $(seq 1 40); do
  STATUS="$(aws ssm get-command-invocation --command-id "$CMD" --instance-id "$INSTANCE" \
    --query Status --output text 2>/dev/null || echo Pending)"
  [[ "$STATUS" =~ ^(Success|Failed|Cancelled|TimedOut)$ ]] && break
  sleep 5
done
OUTPUT="$(aws ssm get-command-invocation --command-id "$CMD" --instance-id "$INSTANCE" \
  --query StandardOutputContent --output text 2>/dev/null)"
echo "$OUTPUT" | sed 's/^/    /'
if [[ "$STATUS" == "Success" ]] && echo "$OUTPUT" | grep -qx HARDENING_OK && ! echo "$OUTPUT" | grep -q '^FAIL:'; then
  pass "guest baseline verified ($(echo "$OUTPUT" | grep -c '^PASS:') checks)"
else
  fail "guest baseline (command status $STATUS)"
fi

echo "[5/5] Patch compliance reported to the prod baseline..."
BASELINE=""
for _ in $(seq 1 20); do
  BASELINE="$(aws ssm describe-instance-patch-states --instance-ids "$INSTANCE" \
    --query 'InstancePatchStates[0].BaselineId' --output text 2>/dev/null)"
  [[ -n "$BASELINE" && "$BASELINE" != "None" ]] && break
  sleep 15
done
EXPECTED_BASELINE="$(aws ssm get-patch-baseline-for-patch-group --patch-group prod \
  --operating-system AMAZON_LINUX_2023 --query BaselineId --output text)"
expect "scan used the prod patch baseline" "$EXPECTED_BASELINE" "$BASELINE"

clear_creds
echo ""
echo "  Passed: $PASS   Failed: $FAIL"
[[ $FAIL -eq 0 ]]
