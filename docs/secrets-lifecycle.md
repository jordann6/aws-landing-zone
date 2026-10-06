# Secrets lifecycle

The `secrets/` root grants the secrets-lifecycle scanner
([aws-secrets-lifecycle](https://github.com/jordann6/aws-secrets-lifecycle))
metadata-only access to all eight member accounts. The scanner runs in the
security account, the GuardDuty and Security Hub delegated admin, never in
management: management is exempt from SCPs and should hold only org-level
resources. Account ids come from the persistent `accounts/` state; none are
hardcoded.

Status: code complete, not yet applied. The live proof below is pending.

## Access model

Each member account gets one `secops-scan-target-role`. This root creates seven
of them; the scanner's own deployment creates the security account's. Each
trust policy allows only the exact scanner role ARN, and this root's seven also
require the caller to be inside this organization (`aws:PrincipalOrgID`). Metadata permissions are scoped to the target account
wherever the API supports resource-level IAM. Explicit denies block
`GetSecretValue`, `BatchGetSecretValue`, every SSM parameter read and
`kms:Decrypt`, so the scanner can inventory and age credentials but never read
one.

The scanner side restricts its own `sts:AssumeRole` to exactly the ARNs this
root outputs, passed in through a gitignored variable file. That file also sets
the security-account deploy role, turns off Security Hub enablement (the
security account already runs it) and keeps the dashboard private, since it
lists secret names and the principals that read them.

The analyzer's consumer mapping reads a single-account trail in the security
account, so consumer maps cover the home account only. Mapping consumers across
the organization would mean querying the org trail in log-archive; that is not
built.

## Ninety-day monitoring

The scanner reads AWSCURRENT version metadata without retrieving values. Age
uses the current version's creation date, so a renewed key in an old secret
container is not flagged as stale, and an enabled rotation schedule does not
hide an overdue credential. Missing current versions or invalid timestamps are
also flagged.

After every complete scan the scanner emits two CloudWatch metrics in embedded
metric format (`SecOps/Secrets`). One alarm fires when any credential needs
attention; a second fires after two daily periods without a completed scan, so
a failed cross-account sweep (an AccessDenied, for example) can never look
healthy. Both publish ALARM and OK to a customer-key-encrypted SNS topic.

Incremental standing cost is about $1.80/month (one KMS key, two custom
metrics, two alarms), plus the scanner's normal Lambda, DynamoDB and S3 usage.
The target roles themselves are $0. No hourly compute or networking is added.

## Operator steps (saved plans only)

Apply the role plan before the scanner plan.

```bash
terraform -chdir=secrets init
terraform -chdir=secrets plan -out=tfplan
terraform -chdir=secrets apply tfplan
python3 scripts/export-scan-targets.py \
  --destination ../aws-secrets-lifecycle/terraform/lz-targets.tfvars.json
```

The export writes role ARNs and scanner settings to a mode-0600, gitignored
variable file. Use `--plan` to export from the reviewed saved plan before it is
applied.

```bash
make -C ../aws-secrets-lifecycle build
terraform -chdir=../aws-secrets-lifecycle/terraform plan \
  -var-file=lz-targets.tfvars.json -out=tfplan
terraform -chdir=../aws-secrets-lifecycle/terraform apply tfplan
```

## Live proof

Run one synchronous scan, then read the logs, metrics and alarms:

```bash
aws lambda invoke --region us-east-1 --function-name secops-scanner \
  --cli-read-timeout 360 --cli-binary-format raw-in-base64-out \
  --payload '{}' scan-result.json
aws logs filter-log-events --region us-east-1 \
  --log-group-name /aws/lambda/secops-scanner --filter-pattern '"SecOps/Secrets"'
aws cloudwatch list-metrics --region us-east-1 --namespace SecOps/Secrets
aws cloudwatch describe-alarms --region us-east-1 \
  --alarm-names secops-secret-age secops-secret-scan-missing \
  --query 'MetricAlarms[].{Name:AlarmName,State:StateValue,Reason:StateReason}'
```

Pass criteria: no `FunctionError`, the EMF event shows `ScanCompleted: 1`, and
the inventory holds rows from all eight member accounts. A denial proof assumes
a target role and confirms `GetSecretValue` returns AccessDenied. Daily alarms
are not immediate smoke-test signals; allow ingestion and evaluation time.

Unit tests in the scanner cover the exact 90-day boundary. Disposable empty and
renewed secrets can verify classification live; delete them afterward.

## Teardown

Destroy the scanner's demo layer through a saved destroy plan and its
Object-Lock evidence cleanup. The target roles can stay at $0, or be destroyed
with their own saved plan when the integration is retired.
