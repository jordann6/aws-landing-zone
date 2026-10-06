#!/usr/bin/env bash
#
# build-image.sh: stage the role, run the golden AMI pipeline once, and wait.
# Image Builder bakes on one instance, then boots a second from the new AMI and
# runs check-hardening.sh; the AMI is only distributed if that test passes.
# Cost: two t3.small instances for ~30-45 minutes, plus a 10 GiB snapshot.

set -euo pipefail
# shellcheck source=scripts/lib-assume.sh
source "$(dirname "$0")/lib-assume.sh"

"$ROOT/scripts/stage-role.sh"

PIPELINE="$(workload_output golden_image_pipeline_arn)"
assume "$(account_output prod_account_id)" build-image
IMAGE="$(aws imagebuilder start-image-pipeline-execution --pipeline-arn "$PIPELINE" \
  --query imageBuildVersionArn --output text)"
echo "Started $IMAGE"

deadline=$((SECONDS + 5400))
while :; do
  STATUS="$(aws imagebuilder get-image --image-build-version-arn "$IMAGE" --query image.state.status --output text)"
  echo "  $(date +%H:%M:%S) $STATUS"
  case "$STATUS" in
    AVAILABLE) break ;;
    FAILED|CANCELLED|DELETED)
      aws imagebuilder get-image --image-build-version-arn "$IMAGE" --query image.state.reason --output text
      exit 1 ;;
  esac
  ((SECONDS < deadline)) || { echo "Timed out waiting for the image build"; exit 1; }
  sleep 60
done

AMI="$(aws imagebuilder get-image --image-build-version-arn "$IMAGE" \
  --query 'image.outputResources.amis[0].image' --output text)"
clear_creds
echo "Golden AMI ready: $AMI"
