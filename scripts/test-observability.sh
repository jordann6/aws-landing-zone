#!/usr/bin/env bash
#
# test-observability.sh: prove the Phase A wiring delivers, not just that apply
# succeeded.
#   1. A GuardDuty sample finding at HIGH severity reaches the security-findings
#      topic (EventBridge invoked the target with no failed invocations, and SNS
#      counted the publish).
#   2. The monitoring account sees prod and network as linked sources, and can
#      list metrics owned by each.
#   3. An alarm forced into ALARM executes its SNS action on the ops topic. The
#      alarm history records success or a KMS/permission failure verbatim.
#
# Needs management-account credentials that can assume OrganizationAccountAccessRole.

export AWS_PAGER=""
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REGION="${AWS_REGION:-us-east-1}"
fail=0
pass() { echo "  PASS: $*"; }
failc() { echo "  FAIL: $*"; fail=1; }

acct() { terraform -chdir="$ROOT/accounts" output -raw "$1"; }
SECURITY_ID="$(acct security_account_id)"
MONITORING_ID="$(acct shared_services_account_id)"
PROD_ID="$(acct prod_account_id)"
NETWORK_ID="$(acct network_account_id)"

# Run a command as OrganizationAccountAccessRole in the given account.
as_account() {
  local id="$1"; shift
  local creds
  creds="$(aws sts assume-role --role-arn "arn:aws:iam::${id}:role/OrganizationAccountAccessRole" \
    --role-session-name obs-test --query Credentials --output json)" || return 1
  AWS_ACCESS_KEY_ID="$(jq -r .AccessKeyId <<<"$creds")" \
  AWS_SECRET_ACCESS_KEY="$(jq -r .SecretAccessKey <<<"$creds")" \
  AWS_SESSION_TOKEN="$(jq -r .SessionToken <<<"$creds")" \
  AWS_REGION="$REGION" "$@"
}

# Sum of a metric over the last N minutes, in one account.
metric_sum() {
  local id="$1" ns="$2" name="$3" dims="$4" minutes="$5"
  as_account "$id" aws cloudwatch get-metric-statistics --namespace "$ns" --metric-name "$name" \
    --dimensions $dims --statistics Sum --period 60 \
    --start-time "$(date -u -v-"${minutes}"M +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u -d "-${minutes} min" +%Y-%m-%dT%H:%M:%SZ)" \
    --end-time "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
    --query 'sum(Datapoints[].Sum)' --output text 2>/dev/null
}

echo "==> 1. GuardDuty sample finding -> security-findings topic"
DETECTOR="$(as_account "$SECURITY_ID" aws guardduty list-detectors --query 'DetectorIds[0]' --output text)"
as_account "$SECURITY_ID" aws guardduty create-sample-findings --detector-id "$DETECTOR" \
  --finding-types "Backdoor:EC2/C&CActivity.B!DNS" >/dev/null \
  && echo "  sample finding created (severity 8, HIGH); waiting for metrics (up to 6 min)" \
  || failc "could not create a sample finding"

TOPIC_NAME="security-findings"
invoked=0; failed=0; published=0
for _ in $(seq 1 12); do
  sleep 30
  invoked="$(metric_sum "$SECURITY_ID" AWS/Events Invocations "Name=RuleName,Value=guardduty-high-critical" 10)"
  failed="$(metric_sum "$SECURITY_ID" AWS/Events FailedInvocations "Name=RuleName,Value=guardduty-high-critical" 10)"
  published="$(metric_sum "$SECURITY_ID" AWS/SNS NumberOfMessagesPublished "Name=TopicName,Value=$TOPIC_NAME" 10)"
  [[ "$published" != "None" && "${published%.*}" -ge 1 ]] 2>/dev/null && break
done
[[ "$failed" != "None" && "${failed%.*}" -ge 1 ]] 2>/dev/null \
  && failc "EventBridge FailedInvocations=$failed (check the topic policy and KMS key policy)"
[[ "$published" != "None" && "${published%.*}" -ge 1 ]] 2>/dev/null \
  && pass "rule invoked ($invoked), SNS published ($published) to $TOPIC_NAME" \
  || failc "no publish on $TOPIC_NAME (invocations=$invoked, failed=$failed)"

echo "==> 2. Monitoring account sees prod and network"
SINK="$(as_account "$MONITORING_ID" aws oam list-sinks --query 'Items[0].Arn' --output text)"
LINKED="$(as_account "$MONITORING_ID" aws oam list-attached-links --sink-identifier "$SINK" \
  --query 'Items[].LinkArn' --output text)"
for pair in "prod:$PROD_ID" "network:$NETWORK_ID"; do
  name="${pair%%:*}"; id="${pair##*:}"
  grep -q ":${id}:" <<<"$LINKED" && pass "$name account linked to the sink" || failc "$name account not linked"
  count="$(as_account "$MONITORING_ID" aws cloudwatch list-metrics --include-linked-accounts \
    --owning-account "$id" --query 'length(Metrics)' --output text 2>/dev/null)"
  [[ "${count:-0}" -ge 1 ]] 2>/dev/null \
    && pass "$count metrics from $name visible in the monitoring account" \
    || failc "no $name metrics visible yet (a fresh link can take a few minutes; is the layer deployed?)"
done

echo "==> 3. Forced alarm -> ops topic"
ALARM="backup-job-failed"
as_account "$MONITORING_ID" aws cloudwatch set-alarm-state --alarm-name "$ALARM" \
  --state-value ALARM --state-reason "test-observability.sh forced state" \
  || failc "could not set $ALARM to ALARM"
action=""
for _ in $(seq 1 12); do
  sleep 5
  action="$(as_account "$MONITORING_ID" aws cloudwatch describe-alarm-history --alarm-name "$ALARM" \
    --history-item-type Action --max-records 1 --query 'AlarmHistoryItems[0].HistorySummary' --output text)"
  [[ "$action" == *"action"* ]] && break
done
if [[ "$action" == Successfully* ]]; then
  pass "$action"
else
  failc "alarm action did not succeed: ${action:-no action recorded}"
fi
# Put it back; the next evaluation would anyway.
as_account "$MONITORING_ID" aws cloudwatch set-alarm-state --alarm-name "$ALARM" \
  --state-value OK --state-reason "test-observability.sh reset" >/dev/null

echo ""
if [[ $fail -ne 0 ]]; then
  echo "test-observability: FAILED"
  exit 1
fi
echo "test-observability: all checks passed"
