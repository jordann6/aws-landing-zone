#!/usr/bin/env bash
# Prove rotation under load: three forced rotations while the reporting client
# queries continuously, and not one failed query.
#
# Run after scripts/rotation-bootstrap.sh. Takes ~15 minutes, most of it waiting.
# Receipts land in .artifacts/rotation-proof/<timestamp>/ (gitignored):
#   versions-<n>.json  version ids, stages and creation dates after each rotation
#                      (AWSCURRENT's CreatedDate is the age the secrets scanner reads)
#   load-failed.json   every failed query (the claim is that this is empty)
#   load-summary.json  the client's own count: queries, ok, failed, retried, users
#   rotation.log       the function's createSecret/setSecret/testSecret/finishSecret lines
#
# PASS needs: zero failed queries, both alternating users seen by the client, and
# three completed rotations.
set -euo pipefail
# shellcheck source=scripts/lib-assume.sh
source "$(dirname "$0")/lib-assume.sh"

ROTATIONS="${ROTATIONS:-3}"
DURATION="${DURATION:-840}"   # load client run time, seconds (Lambda cap 870)
GAP="${GAP:-120}"             # seconds of steady load between rotations

secret_arn="$(workload_output reporting_secret_arn)"
load_fn="$(workload_output reporting_load_lambda_name)"
rotation_fn="$(workload_output rotation_lambda_arn)"
rotation_fn="${rotation_fn##*:}"
out="$ROOT/.artifacts/rotation-proof/$(date -u +%Y%m%dT%H%M%SZ)"
mkdir -p "$out"

assume "$(account_output prod_account_id)" rotation-proof

snapshot() {
  aws secretsmanager list-secret-version-ids --secret-id "$secret_arn" --include-deprecated \
    --query 'Versions[].{id:VersionId,stages:VersionStages,created:CreatedDate}' --output json > "$out/versions-$1.json"
  echo "  versions-$1: $(jq -c '[.[] | select(.stages | length > 0) | {stages, created}]' "$out/versions-$1.json")"
}

current_user() {
  aws secretsmanager get-secret-value --secret-id "$secret_arn" --query SecretString --output text | jq -r .username
}

wait_for_current() {
  local token="$1" deadline=$((SECONDS + 240))
  while (( SECONDS < deadline )); do
    if aws secretsmanager describe-secret --secret-id "$secret_arn" --output json \
         | jq -e --arg t "$token" '.VersionIdsToStages[$t] // [] | index("AWSCURRENT")' >/dev/null; then
      return 0
    fi
    sleep 5
  done
  return 1
}

# A rotation left half-done blocks the next one: refuse to start on top of it.
if aws secretsmanager describe-secret --secret-id "$secret_arn" --output json \
     | jq -e '[.VersionIdsToStages[] | select(index("AWSPENDING") and (index("AWSCURRENT") | not))] | length > 0' >/dev/null; then
  echo "rotation-proof: an AWSPENDING version is outstanding; check the rotation function's logs first." >&2
  exit 1
fi

start_ms=$(( $(date +%s) * 1000 ))
echo "rotation-proof: starting the reporting load client for ${DURATION}s"
aws lambda invoke --function-name "$load_fn" --invocation-type Event \
  --cli-binary-format raw-in-base64-out \
  --payload "{\"duration_seconds\": $DURATION, \"rate_per_second\": 5}" /dev/null >/dev/null
load_ends=$(( SECONDS + DURATION ))

sleep 60
echo "rotation-proof: before rotation, current user $(current_user)"
snapshot 0

for n in $(seq 1 "$ROTATIONS"); do
  token="$(aws secretsmanager rotate-secret --secret-id "$secret_arn" --query VersionId --output text)"
  if ! wait_for_current "$token"; then
    echo "rotation-proof: rotation $n did not finish in 4 minutes" >&2
    exit 1
  fi
  echo "rotation-proof: rotation $n done, current user $(current_user)"
  snapshot "$n"
  sleep "$GAP"
done

remaining=$(( load_ends - SECONDS + 30 ))
if (( remaining > 0 )); then
  echo "rotation-proof: rotations done; waiting ${remaining}s for the load client to finish"
  sleep "$remaining"
fi

logs() {
  aws logs filter-log-events --log-group-name "/aws/lambda/$1" --start-time "$start_ms" \
    --filter-pattern "$2" --query 'events[].message' --output json
}
summary=""
for _ in $(seq 1 12); do
  summary="$(logs "$load_fn" '{ $.summary IS TRUE }' | jq -r '.[-1] // empty')"
  [[ -n "$summary" ]] && break
  sleep 10   # CloudWatch delivery lags a little
done
[[ -n "$summary" ]] || { echo "rotation-proof: no summary from the load client" >&2; exit 1; }
printf '%s\n' "$summary" | jq . > "$out/load-summary.json"
logs "$load_fn" '{ $.ok IS FALSE }' | jq '[.[] | fromjson]' > "$out/load-failed.json"
logs "$rotation_fn" '?createSecret ?setSecret ?testSecret ?finishSecret' | jq -r '.[]' > "$out/rotation.log"

jq . "$out/load-summary.json"
failed="$(jq .failed "$out/load-summary.json")"
users="$(jq -r '.users | join(",")' "$out/load-summary.json")"
finished="$(grep -c 'finishSecret: Successfully set AWSCURRENT' "$out/rotation.log" || true)"

both_users=false
jq -e '.users | (index("orders_reporting") != null) and (index("orders_reporting_clone") != null)' \
  "$out/load-summary.json" >/dev/null && both_users=true

if [[ "$failed" == 0 && "$both_users" == true && "$finished" -ge "$ROTATIONS" ]]; then
  echo "rotation-proof: PASS. $ROTATIONS rotations under load, users $users, zero failed queries. Receipts: $out"
else
  echo "rotation-proof: FAIL. failed=$failed users=$users finished=$finished. Receipts: $out" >&2
  exit 1
fi
