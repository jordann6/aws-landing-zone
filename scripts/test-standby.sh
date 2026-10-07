#!/usr/bin/env bash
#
# test-standby.sh: prove the Phase D warm standby in the prod account, post-deploy.
# Steady state, then break the primary and watch DNS flip and the replica promote.
# Fail closed: outputs are read from state BEFORE assuming into prod, and the
# caller account is verified. Takes about 10 minutes; run it with bash, not source.
# Under `!` a run over 120s moves to the background, so read its output file.

export AWS_PAGER=""
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
out() { terraform -chdir="$ROOT/standby" output -raw "$1"; }

PRIMARY="$(out primary_api_endpoint)" || exit 1
SECONDARY="$(out secondary_api_endpoint)" || exit 1
APP_FQDN="$(out app_fqdn)" || exit 1
ZONE="$(out hosted_zone_id)" || exit 1
REPLICA="$(out replica_identifier)" || exit 1
FAILOVER_FN="$(out failover_function_name)" || exit 1
PRIMARY_FN="$(out primary_api_function_name)" || exit 1
PROD_ID="$(terraform -chdir="$ROOT/accounts" output -raw prod_account_id)" || exit 1
[[ -n "$PRIMARY" && -n "$SECONDARY" && -n "$PROD_ID" ]] || { echo "missing outputs"; exit 1; }

creds="$(aws sts assume-role --role-arn "arn:aws:iam::${PROD_ID}:role/OrganizationAccountAccessRole" \
  --role-session-name standby-test --query Credentials --output json)" || { echo "assume failed"; exit 1; }
AWS_ACCESS_KEY_ID="$(echo "$creds" | python3 -c 'import sys,json;print(json.load(sys.stdin)["AccessKeyId"])')"
AWS_SECRET_ACCESS_KEY="$(echo "$creds" | python3 -c 'import sys,json;print(json.load(sys.stdin)["SecretAccessKey"])')"
AWS_SESSION_TOKEN="$(echo "$creds" | python3 -c 'import sys,json;print(json.load(sys.stdin)["SessionToken"])')"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
[[ "$(aws sts get-caller-identity --query Account --output text)" == "$PROD_ID" ]] || { echo "wrong account"; exit 1; }

PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }
code() { curl -s -o /dev/null -w '%{http_code}' "$@"; }
dns() { aws route53 test-dns-answer --hosted-zone-id "$ZONE" --record-name "$APP_FQDN" --record-type CNAME \
  --query 'RecordData[0]' --output text; }
rdb() { aws rds describe-db-instances --region us-west-2 --db-instance-identifier "$REPLICA" "$@"; }
JSON='Content-Type: application/json'

echo "[1/8] both regions healthy..."
if [[ "$(code "$PRIMARY/health")" == 200 && "$(code "$SECONDARY/health")" == 200 ]]; then pass "both /health 200"; else fail "health"; fi

echo "[2/8] replica is encrypted with the multi-region CMK replica in us-west-2..."
KEY="$(rdb --query 'DBInstances[0].KmsKeyId' --output text)"
RKEY="$(aws kms describe-key --region us-west-2 --key-id alias/lz-standby-data --query 'KeyMetadata.Arn' --output text)"
RMR="$(aws kms describe-key --region us-west-2 --key-id alias/lz-standby-data --query 'KeyMetadata.MultiRegion' --output text)"
if [[ "$RKEY" == "$KEY" && "$RMR" == "True" ]]; then pass "replica uses the multi-region replica key"; else fail "key=$KEY alias=$RKEY"; fi

echo "[3/8] write on primary, read from standby (replication)..."
code -X POST "$PRIMARY/orders" -H "$JSON" -d '{"item":"standby-proof","quantity":1}' >/dev/null
seen=no
for _ in $(seq 1 12); do
  curl -s "$SECONDARY/orders" | grep -q standby-proof && { seen=yes; break; }
  sleep 5
done
if [[ $seen == yes ]]; then pass "row replicated to us-west-2"; else fail "row not visible on standby"; fi

echo "[4/8] standby rejects writes while it is a replica..."
if [[ "$(code -X POST "$SECONDARY/orders" -H "$JSON" -d '{"item":"nope"}')" == 409 ]]; then pass "409 on standby write"; else fail "expected 409"; fi

echo "[5/8] DNS answers with the primary while healthy..."
BEFORE="$(dns)"
echo "  answer: $BEFORE"
if [[ "$BEFORE" == *"${PRIMARY#https://}"* ]]; then pass "primary answered"; else fail "expected primary"; fi

echo "[6/8] break the primary and wait for DNS to flip..."
aws lambda update-function-configuration --region us-east-1 --function-name "$PRIMARY_FN" \
  --environment "Variables={SIMULATE_FAILURE=true}" >/dev/null || fail "could not break primary"
flipped=no
for _ in $(seq 1 24); do
  AFTER="$(dns)"
  [[ "$AFTER" == *"${SECONDARY#https://}"* ]] && { flipped=yes; break; }
  sleep 10
done
echo "  answer: $AFTER"
if [[ $flipped == yes ]]; then pass "DNS now answers with us-west-2"; else fail "DNS did not flip"; fi

echo "[7/8] failover Lambda promotes the replica..."
promoted=no
for _ in $(seq 1 60); do
  src="$(rdb --query 'DBInstances[0].ReadReplicaSourceDBInstanceIdentifier' --output text 2>/dev/null)"
  st="$(rdb --query 'DBInstances[0].DBInstanceStatus' --output text 2>/dev/null)"
  [[ "$src" == "None" && "$st" == "available" ]] && { promoted=yes; break; }
  sleep 15
done
if [[ $promoted == yes ]]; then pass "replica promoted and available"; else fail "not promoted (status=$st source=$src)"; fi
aws logs tail "/aws/lambda/$FAILOVER_FN" --region us-west-2 --since 30m 2>/dev/null | grep -m3 "Failover\|Promotion" | sed 's/^/  log: /'

echo "[8/8] standby now accepts writes..."
if [[ "$(code -X POST "$SECONDARY/orders" -H "$JSON" -d '{"item":"written-after-failover"}')" == 201 ]]; then pass "write accepted in us-west-2"; else fail "write not accepted"; fi

echo
echo "standby test: $PASS passed, $FAIL failed"
echo "The replica is promoted: destroy, never re-apply."
[[ $FAIL -eq 0 ]]
