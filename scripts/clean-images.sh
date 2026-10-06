#!/usr/bin/env bash
#
# clean-images.sh: delete every golden AMI, its snapshots, and its Image Builder
# image record from the prod account. Runs before the workload destroy so the
# recipe can be deleted and no snapshot outlives the EBS key that encrypts it.

set -uo pipefail
# shellcheck source=scripts/lib-assume.sh
source "$(dirname "$0")/lib-assume.sh"

assume "$(account_output prod_account_id)" clean-images || { echo "could not assume into prod"; exit 1; }

for arn in $(aws imagebuilder list-images --owner Self --query 'imageVersionList[].arn' --output text); do
  for build in $(aws imagebuilder list-image-build-versions --image-version-arn "$arn" \
      --query 'imageSummaryList[].arn' --output text); do
    aws imagebuilder delete-image --image-build-version-arn "$build" >/dev/null && echo "deleted image record $build"
  done
done

# Match on the name as well as the tag: a bake that fails its test phase leaves
# an AMI from the build instance, untagged because tags are applied only at
# distribution.
for ami in $( (aws ec2 describe-images --owners self --filters Name=tag:GoldenImage,Values=true \
      --query 'Images[].ImageId' --output text
    aws ec2 describe-images --owners self --filters 'Name=name,Values=lz-hardened-al2023-*' \
      --query 'Images[].ImageId' --output text) | tr '\t' '\n' | sort -u); do
  snaps="$(aws ec2 describe-images --image-ids "$ami" \
    --query 'Images[0].BlockDeviceMappings[].Ebs.SnapshotId' --output text)"
  aws ec2 deregister-image --image-id "$ami" && echo "deregistered $ami"
  for snap in $snaps; do
    aws ec2 delete-snapshot --snapshot-id "$snap" && echo "deleted $snap"
  done
done
clear_creds
