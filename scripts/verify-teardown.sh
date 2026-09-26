#!/usr/bin/env bash
#
# verify-teardown.sh: fail if anything that bills by the hour survived a destroy.
# The topology and guardrail layer is nearly free; the whole cost risk is a
# forgotten NAT gateway, Network Firewall, endpoint, or database.

set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"

HOURLY='aws_nat_gateway|aws_networkfirewall_firewall|aws_vpc_endpoint|aws_ec2_transit_gateway|aws_db_instance|aws_rds_cluster|aws_eks_cluster|aws_eks_node_group|aws_instance|aws_lb'

fail=0
for dir in terraform network workload; do
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

if [[ $fail -ne 0 ]]; then
  echo ""
  echo "verify-teardown: FAILED. Something billable is still standing."
  exit 1
fi
echo ""
echo "verify-teardown: clean. Standing footprint is KMS only."
