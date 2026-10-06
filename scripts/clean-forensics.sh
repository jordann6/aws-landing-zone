#!/usr/bin/env bash
#
# clean-forensics.sh: delete the forensics runbook's snapshots from the prod
# account. The runbook creates them at incident time (source snapshots, then
# copies encrypted with the security account's evidence key), so they are in no
# Terraform state. Evidence is kept by design; this is for demo teardown, after
# the evidence manifest in the security account has been reviewed.

set -uo pipefail
# shellcheck source=scripts/lib-assume.sh
source "$(dirname "$0")/lib-assume.sh"

prod_id="$(account_output prod_account_id)" || { echo "no prod account id in accounts state"; exit 1; }
assume "$prod_id" clean-forensics || { echo "could not assume into prod"; exit 1; }
caller="$(aws sts get-caller-identity --query Account --output text)"
[[ "$caller" == "$prod_id" ]] || { echo "caller is $caller, not prod; refusing"; exit 1; }

status=0
for snap in $(aws ec2 describe-snapshots --owner-ids self \
    --filters 'Name=tag-key,Values=forensics:stage' --query 'Snapshots[].SnapshotId' --output text); do
  if aws ec2 delete-snapshot --snapshot-id "$snap"; then
    echo "deleted forensics snapshot $snap"
  else
    status=1
  fi
done
clear_creds
exit "$status"
