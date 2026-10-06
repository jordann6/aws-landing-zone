#!/usr/bin/env bash
#
# migrate-state-backend.sh: move every root's state from the legacy shared bucket
# (tf-state-jordprojs, aws-scp-governance/ keys) into the dedicated backend that
# bootstrap/state_backend.tf creates (ADR-0003). Nothing here applies; the
# operator applies the phase 1 plan.
#
#   phase1  bootstrap plan against the LEGACY backend. Applying it creates the
#           new bucket, CMK and alias, and widens the CI roles to both buckets.
#   phase2  per root, in dependency order: count resources on the legacy backend,
#           init -migrate-state -force-copy to the new backend, count again, and
#           fail loudly on any mismatch. Roots with no legacy object are skipped.
#
# The legacy backend is selected through a temporary backend_override.tf
# (gitignored) rather than -backend-config flags, because an override file
# replaces the whole backend block and so drops kms_key_id, which -backend-config
# cannot unset. Phase 2 inits every root against the legacy backend first, so it
# does not depend on whatever an existing .terraform/ directory last pointed at.
#
# The legacy objects are never deleted; they are the rollback. They stay valid
# only until the first apply against the new backend, after which they are stale.
# Do not plan or apply any root until phase 2 finishes, merge this branch, and
# rebase open branches before their next apply.

export AWS_PAGER=""
set -uo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
REGION="us-east-1"
OLD_BUCKET="tf-state-jordprojs"
OLD_PREFIX="aws-scp-governance"
NEW_BUCKET="jordann6-aws-landing-zone-tfstate"
NEW_PREFIX="aws-landing-zone"
# Dependency order: accounts is read by terraform, network and observability.
ROOTS=(bootstrap accounts terraform network workload observability)

die() { echo "migrate-state-backend: FAIL: $*" >&2; exit 1; }

write_override() {
  cat >"$ROOT/$1/backend_override.tf" <<EOF
# TEMPORARY, written by scripts/migrate-state-backend.sh. Gitignored.
terraform {
  backend "s3" {
    bucket       = "$OLD_BUCKET"
    key          = "$OLD_PREFIX/$1.tfstate"
    region       = "$REGION"
    use_lockfile = true
    encrypt      = true
  }
}
EOF
}

clear_overrides() {
  local r
  for r in "${ROOTS[@]}"; do rm -f "$ROOT/$r/backend_override.tf"; done
}

object_exists() { aws s3api head-object --bucket "$1" --key "$2" >/dev/null 2>&1; }

count_state() {
  local out
  out="$(terraform -chdir="$ROOT/$1" state list 2>&1)" || die "$1: state list failed: $out"
  grep -c . <<<"$out" || true
}

tf_init() {
  local r="$1"
  shift
  terraform -chdir="$ROOT/$r" init -input=false -no-color "$@" >"$ROOT/$r/.migrate-init.log" 2>&1 ||
    die "$r: terraform init $* failed (see $r/.migrate-init.log)"
}

phase1() {
  trap clear_overrides EXIT
  object_exists "$OLD_BUCKET" "$OLD_PREFIX/bootstrap.tfstate" || die "no legacy bootstrap state"
  write_override bootstrap
  tf_init bootstrap -reconfigure
  terraform -chdir="$ROOT/bootstrap" plan -input=false -out=tfplan || die "bootstrap plan failed"
  # Keep the override so the apply writes state to the legacy bucket.
  trap - EXIT
  echo
  echo "Phase 1 plan saved: bootstrap/tfplan (state stays in $OLD_BUCKET)."
  echo "Expect only creates (bucket, its config, key, alias) and in-place role policy updates."
  echo "Apply:  terraform -chdir=$ROOT/bootstrap apply tfplan"
  echo "Then:   $0 phase2"
}

phase2() {
  trap clear_overrides EXIT
  aws s3api head-bucket --bucket "$NEW_BUCKET" >/dev/null 2>&1 ||
    die "$NEW_BUCKET does not exist or is not ours; apply phase 1 first"
  local algo
  algo="$(aws s3api get-bucket-encryption --bucket "$NEW_BUCKET" \
    --query 'ServerSideEncryptionConfiguration.Rules[0].ApplyServerSideEncryptionByDefault.SSEAlgorithm' \
    --output text 2>&1)"
  [[ "$algo" == "aws:kms" ]] || die "$NEW_BUCKET default encryption is '$algo', expected aws:kms"

  local r before after sse
  for r in "${ROOTS[@]}"; do
    echo "== $r"
    if ! object_exists "$OLD_BUCKET" "$OLD_PREFIX/$r.tfstate"; then
      echo "  SKIP: no legacy object $OLD_PREFIX/$r.tfstate"
      continue
    fi

    write_override "$r"
    tf_init "$r" -reconfigure
    before="$(count_state "$r")" || exit 1
    rm -f "$ROOT/$r/backend_override.tf"

    if object_exists "$NEW_BUCKET" "$NEW_PREFIX/$r.tfstate"; then
      tf_init "$r" -reconfigure
      after="$(count_state "$r")" || exit 1
      [[ "$before" == "$after" ]] ||
        die "$r: new object already exists with $after resources vs $before on the legacy backend; resolve by hand"
      echo "  already migrated: $after resources on both backends"
      continue
    fi

    tf_init "$r" -migrate-state -force-copy
    after="$(count_state "$r")" || exit 1
    [[ "$before" == "$after" ]] ||
      die "$r: resource count mismatch after migration (legacy $before, new $after). Legacy object is untouched."
    sse="$(aws s3api head-object --bucket "$NEW_BUCKET" --key "$NEW_PREFIX/$r.tfstate" \
      --query ServerSideEncryption --output text 2>&1)"
    [[ "$sse" == "aws:kms" ]] || die "$r: migrated object encryption is '$sse', expected aws:kms"
    echo "  migrated: $before resources, SSE $sse"
  done
  echo
  echo "Phase 2 complete. Legacy objects under s3://$OLD_BUCKET/$OLD_PREFIX/ are untouched (rollback)."
}

case "${1:-}" in
  phase1) phase1 ;;
  phase2) phase2 ;;
  *) echo "usage: $0 phase1|phase2" >&2; exit 2 ;;
esac
