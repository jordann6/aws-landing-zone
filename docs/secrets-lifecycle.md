# Secrets lifecycle

The `secrets/` root grants the secrets-lifecycle scanner
([aws-secrets-lifecycle](https://github.com/jordann6/aws-secrets-lifecycle))
metadata-only access to all eight member accounts. The scanner runs in the
security account, the GuardDuty and Security Hub delegated admin, never in
management: management is exempt from SCPs and should hold only org-level
resources. Account ids come from the persistent `accounts/` state; none are
hardcoded.

Status: live in the security account and proven 2026-10-06 (results below).
The scanner is a standing detective control, not an hourly layer.

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

Standing cost is a few dollars a month: about $1.80 for one KMS key, two custom
metrics and two alarms, plus the analyzer's single-account trail. The org trail
already records the security account's management events, so that trail is a
second, billed copy; it is the variable part of the bill. Lambda, DynamoDB and
S3 usage are negligible on a daily schedule. The target roles are $0. No hourly
compute or networking is added.

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

## Live proof (2026-10-06)

Every check below ran inside the security account, through a role session that
fails closed if the assume does not land there. The scripted invoke is
synchronous and runs the scanner only.

Baseline scan, all eight accounts:

```text
invoke   StatusCode 200, no FunctionError
         {"scan_id":"20261006T170022Z","secrets_scanned":0,"wall_clock_seconds":1.23}
EMF      {"ScanCompleted":1,"Scanner":"secops-scanner","SecretsNeedingAttention":0,...}
assumes  CloudTrail AssumeRole into secops-scan-target-role: 7/7 target accounts
```

Zero is the true count: no account holds a Secrets Manager secret, a
SecureString parameter or an IAM access key. Prod holds one AWS-managed
Inspector StringList parameter, which the scanner skips by design. A failed
assume or sweep returns an error and fails the invocation, so a clean exit plus
seven AssumeRole events proves every target was swept.

Positive control: an empty secret shell created in sandbox, scanned, then
force-deleted by the same script:

```text
invoke     {"scan_id":"20261006T170411Z","secrets_scanned":1}
inventory  account_id 231161110714 (sandbox), kind secretsmanager,
           name secops-positive-control, rotation_enabled False
EMF        {"ScanCompleted":1,"SecretsNeedingAttention":1,...}
metric     SecretsNeedingAttention 17:00 0.0, 17:04 1.0
```

The age alarm then fired from that single datapoint, about a minute after the
scan:

```text
16:59:05  StateUpdate  INSUFFICIENT_DATA -> OK, SNS action executed
17:05:05  StateUpdate  OK -> ALARM
17:05:05  Action       Successfully executed action ...:secops-secret-alerts
SNS       NumberOfMessagesPublished 1 (16:55 window), 1 (17:05 window)
```

It returns to OK after the next scheduled scan reports zero.

Denial, IAM policy simulator against the deployed target roles (prod and
security):

```text
allowed       ListSecrets, DescribeSecret, ssm:DescribeParameters, iam:ListUsers
explicitDeny  GetSecretValue, BatchGetSecretValue, ssm:GetParameter,
              ssm:GetParametersByPath, kms:Decrypt (prod)
```

The dashboard bucket has no bucket policy and all four public access block
settings on.

Unit tests cover the exact 90-day boundary. To re-run, invoke the scanner from
a security-account session:

```bash
aws lambda invoke --region us-east-1 --function-name secops-scanner \
  --cli-read-timeout 360 --cli-binary-format raw-in-base64-out \
  --payload '{}' scan-result.json
aws logs filter-log-events --region us-east-1 \
  --log-group-name /aws/lambda/secops-scanner --filter-pattern '"SecOps/Secrets"'
aws cloudwatch describe-alarms --region us-east-1 \
  --alarm-names secops-secret-age secops-secret-scan-missing \
  --query 'MetricAlarms[].{Name:AlarmName,State:StateValue,Reason:StateReason}'
```

## Teardown

Destroy the scanner's demo layer through a saved destroy plan and its
Object-Lock evidence cleanup. The target roles can stay at $0, or be destroyed
with their own saved plan when the integration is retired.
