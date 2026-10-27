#!/usr/bin/env bash
# Create the orders_reporting user, seed its secret, then turn rotation on.
#
# Run once per deploy, after the workload apply and after release-guard's own
# bootstrap (it creates the orders database and schema). The DB is private, so the
# SQL runs as a short-lived Job in EKS through release-guard's kubeconfig: keep
# release-guard's scripts/aws/eks-tunnel.sh open in another terminal.
#
# No password touches a command line, Terraform state, or the terminal. Both the
# master password and the new one travel over stdin into a Secret that is deleted
# with its namespace. Rotation is enabled last, because Secrets Manager tests the
# function as soon as it is configured, and that test needs a real user and value.
#
#   KUBECONFIG  defaults to ~/.kube/release-guard-aws.yaml
set -euo pipefail
# shellcheck source=scripts/lib-assume.sh
source "$(dirname "$0")/lib-assume.sh"

KUBECONFIG="${KUBECONFIG:-$HOME/.kube/release-guard-aws.yaml}"
NS=rotation-bootstrap
kc() { kubectl --kubeconfig "$KUBECONFIG" "$@"; }

secret_arn="$(workload_output reporting_secret_arn)"
rotation_arn="$(workload_output rotation_lambda_arn)"
master_arn="$(workload_output db_secret_arn)"
db_host="$(workload_output db_endpoint)"
registry="$(workload_output ecr_repository_url)"
registry="${registry%%/*}"
[[ -n "$secret_arn" && "$secret_arn" != null ]] || { echo "rotation-bootstrap: no reporting secret in workload outputs (enable_rds off?)" >&2; exit 1; }

assume "$(account_output prod_account_id)" rotation-bootstrap
kc version --request-timeout=10s >/dev/null || { echo "rotation-bootstrap: cannot reach the cluster; is release-guard's eks-tunnel.sh running?" >&2; exit 1; }

# Same alphabet the rotation function uses (its EXCLUDE_CHARACTERS default).
password="$(aws secretsmanager get-random-password --password-length 32 \
  --exclude-characters ":/@\"'\\" --require-each-included-type \
  --query RandomPassword --output text)"
master_password="$(aws secretsmanager get-secret-value --secret-id "$master_arn" \
  --query SecretString --output text | jq -r .password)"

kc create namespace "$NS" --dry-run=client -o yaml | kc apply -f - >/dev/null
trap 'kc delete namespace "$NS" --wait=false >/dev/null 2>&1 || true' EXIT
printf 'PGPASSWORD=%s\nREPORTING_PW=%s\n' "$master_password" "$password" \
  | kc -n "$NS" create secret generic credentials --from-env-file=/dev/stdin \
      --dry-run=client -o yaml | kc apply -f - >/dev/null
unset master_password
kc -n "$NS" create configmap sql --from-file="$ROOT/workload/rotation/reporting-role.sql" \
  --dry-run=client -o yaml | kc apply -f - >/dev/null

kc -n "$NS" delete job reporting-role --ignore-not-found >/dev/null
kc apply -f - >/dev/null <<YAML
apiVersion: batch/v1
kind: Job
metadata:
  name: reporting-role
  namespace: $NS
spec:
  backoffLimit: 1
  activeDeadlineSeconds: 300
  template:
    spec:
      restartPolicy: Never
      automountServiceAccountToken: false
      securityContext:
        runAsNonRoot: true
        runAsUser: 70
        seccompProfile:
          type: RuntimeDefault
      containers:
        - name: psql
          image: $registry/tools/postgres:16-alpine
          env:
            - { name: PGHOST, value: "$db_host" }
            - { name: PGUSER, value: appadmin }
            - { name: PGDATABASE, value: orders }
            - { name: PGSSLMODE, value: require }
          envFrom:
            - secretRef: { name: credentials }
          command: ["sh", "-ec"]
          args:
            - |
              psql -v ON_ERROR_STOP=1 -f /sql/reporting-role.sql
              echo "orders_reporting ready"
          securityContext:
            allowPrivilegeEscalation: false
            capabilities: { drop: [ALL] }
          volumeMounts:
            - { name: sql, mountPath: /sql }
      volumes:
        - name: sql
          configMap: { name: sql }
YAML
if ! kc -n "$NS" wait --for=condition=complete job/reporting-role --timeout=300s >/dev/null; then
  kc -n "$NS" logs job/reporting-role >&2 || true
  echo "rotation-bootstrap: the role Job failed (has release-guard's bootstrap created the orders schema?)" >&2
  exit 1
fi
kc -n "$NS" logs job/reporting-role | tail -1

# The shape the alternating-users function expects. ssl=true means it never falls
# back to plaintext; masterarn is the RDS-managed master secret.
PASSWORD="$password" HOST="$db_host" MASTER="$master_arn" python3 -I -c '
import json, os
print(json.dumps({"engine": "postgres", "host": os.environ["HOST"], "port": 5432,
                  "dbname": "orders", "username": "orders_reporting",
                  "password": os.environ["PASSWORD"], "masterarn": os.environ["MASTER"],
                  "ssl": True}))' \
  | aws secretsmanager put-secret-value --secret-id "$secret_arn" \
      --secret-string file:///dev/stdin --query VersionId --output text \
  | sed 's/^/rotation-bootstrap: seeded version /'
unset password

aws secretsmanager rotate-secret --secret-id "$secret_arn" \
  --rotation-lambda-arn "$rotation_arn" \
  --rotation-rules AutomaticallyAfterDays=1 --no-rotate-immediately >/dev/null
echo "rotation-bootstrap: rotation enabled (1 day); Secrets Manager is testing the function now."
echo "rotation-bootstrap: next, scripts/rotation-proof.sh"
