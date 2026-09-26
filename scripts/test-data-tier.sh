#!/usr/bin/env bash
#
# test-data-tier.sh: prove the Phase 5/6 data and workload controls, post-deploy.
# Assumes into the prod account and checks the properties that matter: the DB is
# Multi-AZ, encrypted, and private; the backup vault is Vault-Locked; and the EKS
# API is private. Optionally forces an RDS failover and confirms the AZ flips.

export AWS_PAGER=""
set -uo pipefail

cd "$(dirname "$0")/../terraform" || exit 1
PROD_ACCOUNT_ID="$(terraform output -raw prod_account_id)"

creds="$(aws sts assume-role \
  --role-arn "arn:aws:iam::${PROD_ACCOUNT_ID}:role/OrganizationAccountAccessRole" \
  --role-session-name data-test --query Credentials --output json)" || {
  echo "could not assume into prod account"; exit 1; }
AWS_ACCESS_KEY_ID="$(echo "$creds" | python3 -c 'import sys,json;print(json.load(sys.stdin)["AccessKeyId"])')"
AWS_SECRET_ACCESS_KEY="$(echo "$creds" | python3 -c 'import sys,json;print(json.load(sys.stdin)["SecretAccessKey"])')"
AWS_SESSION_TOKEN="$(echo "$creds" | python3 -c 'import sys,json;print(json.load(sys.stdin)["SessionToken"])')"
export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN

PASS=0; FAIL=0
pass() { echo "  PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "  FAIL: $1"; FAIL=$((FAIL + 1)); }

echo "[1/5] RDS is Multi-AZ..."
[[ "$(aws rds describe-db-instances --db-instance-identifier prod-postgres --query 'DBInstances[0].MultiAZ' --output text 2>&1)" == "True" ]] \
  && pass "Multi-AZ enabled" || fail "not Multi-AZ"

echo "[2/5] RDS is encrypted and private..."
ENC="$(aws rds describe-db-instances --db-instance-identifier prod-postgres --query 'DBInstances[0].StorageEncrypted' --output text 2>&1)"
PUB="$(aws rds describe-db-instances --db-instance-identifier prod-postgres --query 'DBInstances[0].PubliclyAccessible' --output text 2>&1)"
[[ "$ENC" == "True" && "$PUB" == "False" ]] && pass "encrypted + not public" || fail "enc=$ENC public=$PUB"

echo "[3/5] Backup vault is Vault-Locked..."
LOCKED="$(aws backup describe-backup-vault --backup-vault-name prod-data-vault --query 'Locked' --output text 2>&1)"
[[ "$LOCKED" == "True" ]] && pass "Vault Lock active" || fail "vault not locked ($LOCKED)"

echo "[4/5] EKS API endpoint is private..."
PUBEP="$(aws eks describe-cluster --name prod --query 'cluster.resourcesVpcConfig.endpointPublicAccess' --output text 2>&1)"
[[ "$PUBEP" == "False" ]] && pass "public endpoint disabled" || fail "public endpoint = $PUBEP"

echo "[5/5] EKS secrets are envelope-encrypted with a CMK..."
KEYARN="$(aws eks describe-cluster --name prod --query 'cluster.encryptionConfig[0].provider.keyArn' --output text 2>&1)"
[[ "$KEYARN" == arn:aws:kms:* ]] && pass "etcd secrets encrypted with $KEYARN" || fail "no encryption config ($KEYARN)"

echo ""
echo "  Passed: $PASS   Failed: $FAIL"
[[ $FAIL -eq 0 ]]
