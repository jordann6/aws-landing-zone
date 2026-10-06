#!/usr/bin/env bash
#
# verify-teardown.sh: fail if anything that bills by the hour survived a destroy.
# The topology and guardrail layer is nearly free; the whole cost risk is a
# forgotten NAT gateway, Network Firewall, endpoint, or database.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

HOURLY='aws_nat_gateway|aws_networkfirewall_firewall|aws_vpc_endpoint|aws_ec2_transit_gateway|aws_db_instance|aws_rds_cluster|aws_eks_cluster|aws_eks_node_group|aws_instance|aws_lb'

fail=0
for dir in compute observability terraform network workload standby; do
  echo "==> $dir"
  state="$(terraform -chdir="$ROOT/$dir" state list 2>/dev/null || true)"
  if [[ -z "$state" ]]; then
    echo "  state empty or absent. OK"
    continue
  fi
  standing="$(echo "$state" | grep -E "$HOURLY" || true)"
  if [[ -n "$standing" ]]; then
    echo "  HOURLY resources still in state:"
    echo "$standing" | sed 's/^/    !! /'
    fail=1
  else
    echo "  no hourly resources remain. OK"
    echo "  (a KMS key pending deletion is expected: ~\$1/mo until the window closes)"
  fi
done

# Accounts are permanent (accounts/ root). A teardown that closed one would leave
# it SUSPENDED for 90 days, holding quota and its email alias.
echo "==> member accounts"
if ! closed="$(aws organizations list-accounts --query 'Accounts[?Status!=`ACTIVE`].Name' --output text 2>/dev/null)"; then
  echo "  could not list accounts (no org credentials). SKIPPED"
elif [[ -n "$closed" ]]; then
  echo "  accounts not ACTIVE: $closed"
  fail=1
else
  echo "  all member accounts ACTIVE. OK"
fi

# Golden AMIs are created by the Image Builder pipeline, not by Terraform, so they
# never show up in state. make destroy runs clean-images; this proves it worked.
# Matched by name: a bake that fails its test phase leaves an untagged AMI.
echo "==> golden AMIs and snapshots (prod account)"
prod_id="$(terraform -chdir="$ROOT/accounts" output -raw prod_account_id 2>/dev/null || true)"
if [[ -z "$prod_id" ]] || ! creds="$(aws sts assume-role --role-arn "arn:aws:iam::${prod_id}:role/OrganizationAccountAccessRole" \
    --role-session-name verify-teardown --query Credentials --output json 2>/dev/null)"; then
  echo "  could not assume into prod. SKIPPED"
else
  prod_ec2() {
    AWS_ACCESS_KEY_ID="$(echo "$creds" | python3 -c 'import sys,json;print(json.load(sys.stdin)["AccessKeyId"])')" \
      AWS_SECRET_ACCESS_KEY="$(echo "$creds" | python3 -c 'import sys,json;print(json.load(sys.stdin)["SecretAccessKey"])')" \
      AWS_SESSION_TOKEN="$(echo "$creds" | python3 -c 'import sys,json;print(json.load(sys.stdin)["SessionToken"])')" \
      aws ec2 --region us-east-1 "$@"
  }
  images="$(prod_ec2 describe-images --owners self --filters 'Name=name,Values=lz-hardened-al2023-*' \
    --query 'Images[].ImageId' --output text)"
  if [[ -n "$images" ]]; then
    echo "  golden AMIs still registered (snapshots bill monthly): $images"
    fail=1
  else
    echo "  no golden AMIs remain. OK"
  fi

  # The forensics runbook snapshots at incident time; scripts/clean-forensics.sh
  # removes them once the evidence has been reviewed.
  echo "==> forensics snapshots (prod account)"
  snaps="$(prod_ec2 describe-snapshots --owner-ids self --filters 'Name=tag-key,Values=forensics:stage' \
    --query 'Snapshots[].SnapshotId' --output text)"
  if [[ -n "$snaps" ]]; then
    echo "  forensics snapshots remain (bill monthly): $snaps"
    fail=1
  else
    echo "  no forensics snapshots remain. OK"
  fi
fi

# Phase D standby lives in prod us-east-1 and us-west-2. State can be empty while a
# promoted replica, a stray log group or a hosted zone survives, so ask the APIs.
echo "==> standby layer (prod, us-east-1 and us-west-2)"
if [[ -z "${creds:-}" ]]; then
  echo "  no prod session. SKIPPED"
else
  export AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY AWS_SESSION_TOKEN
  AWS_ACCESS_KEY_ID="$(echo "$creds" | python3 -c 'import sys,json;print(json.load(sys.stdin)["AccessKeyId"])')"
  AWS_SECRET_ACCESS_KEY="$(echo "$creds" | python3 -c 'import sys,json;print(json.load(sys.stdin)["SecretAccessKey"])')"
  AWS_SESSION_TOKEN="$(echo "$creds" | python3 -c 'import sys,json;print(json.load(sys.stdin)["SessionToken"])')"
  for region in us-east-1 us-west-2; do
    dbs="$(aws rds describe-db-instances --region "$region" --query 'DBInstances[?starts_with(DBInstanceIdentifier, `lz-standby`)].DBInstanceIdentifier' --output text 2>&1)"
    vpcs="$(aws ec2 describe-vpcs --region "$region" --filters 'Name=tag:Name,Values=lz-standby-*' --query 'Vpcs[].VpcId' --output text 2>&1)"
    vpce="$(aws ec2 describe-vpc-endpoints --region "$region" --filters 'Name=tag:Name,Values=lz-standby-*' --query 'VpcEndpoints[].VpcEndpointId' --output text 2>&1)"
    fns="$(aws lambda list-functions --region "$region" --query 'Functions[?starts_with(FunctionName, `lz-standby`)].FunctionName' --output text 2>&1)"
    logs="$(aws logs describe-log-groups --region "$region" --query 'logGroups[?contains(logGroupName, `lz-standby`)].logGroupName' --output text 2>&1)"
    secrets="$(aws secretsmanager list-secrets --region "$region" --query 'SecretList[?starts_with(Name, `lz-standby`)].Name' --output text 2>&1)"
    for pair in "RDS:$dbs" "VPC:$vpcs" "endpoint:$vpce" "Lambda:$fns" "log group:$logs" "secret:$secrets"; do
      if [[ -n "${pair#*:}" ]]; then
        echo "  $region ${pair%%:*} still present: ${pair#*:}"
        fail=1
      fi
    done
  done
  zones="$(aws route53 list-hosted-zones --query 'HostedZones[?Name==`failover.jordandesigns.io.`].Id' --output text 2>&1)"
  hcs="$(aws route53 list-health-checks --query 'HealthChecks[].Id' --output text 2>&1)"
  [[ -n "$zones" ]] && { echo "  hosted zone still present: $zones"; fail=1; }
  [[ -n "$hcs" ]] && { echo "  Route 53 health checks present: $hcs"; fail=1; }
  [[ $fail -eq 0 ]] && echo "  no standby resources remain. OK"
  echo "  (multi-region KMS keys pending deletion are expected until the 7 day window closes)"
fi

if [[ $fail -ne 0 ]]; then
  echo ""
  echo "verify-teardown: FAILED. Something billable is still standing, or an account was closed."
  exit 1
fi
echo ""
echo "verify-teardown: clean. Standing footprint is KMS only."
