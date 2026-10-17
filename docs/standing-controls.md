# Standing controls: uptime, backup freshness, remediation

Three small roots that stay deployed. Status: **deployed on 2026-10-16 and smoke
checked. The uptime, backup and remediation response-path proofs ran on 2026-10-17
(see Live proof), and real CPU load raised the remediation alarm on its own in dry
run. On the same day a synthetic heartbeat producer started writing to the landing
bucket, and a responder session proved the uptime alarms reach the on-call inbox as
notify-only with a model summary. A stale backup object is not proven yet.** Each root was applied from a saved
plan and its second plan came back empty. The smoke checks were one safe
invocation per Lambda and a read of the bucket settings, not a demonstration of
any control working under failure.

What the smoke checks showed:

- `uptime/`: one invocation reported the site healthy (HTTP 200, 374 ms, 115 days
  of certificate left). The site-down alarm sat in ALARM for the first minutes
  because missing data counts as breaching, then cleared to OK after two checks.
- `backup-verify/`: one invocation reported an empty bucket (0 objects, age 9999).
  The bucket is private (all four public-access blocks on), versioned and
  KMS-encrypted, and `terraform plan -destroy` refuses to remove it.
- `remediation/`: a malformed event was skipped with no action. The state table is
  empty and both email subscriptions are pending confirmation.

One defect only a live apply could find: the account's Lambda concurrency quota is
10, so reserving one execution per function failed (AWS requires 10 unreserved).
The reservation was removed from all three functions. Duplicate runs are made
harmless in code (the conditional write in `remediation/`), not by concurrency.

| Root | Account | What it does | What it does not prove |
| ---- | ------- | ------------ | ---------------------- |
| `uptime/` | shared-services | A Lambda checks jordandesigns.io every 5 minutes (status, optional body text, certificate days left, one retry) and writes metrics and a log row. Alarms for site down, high latency and certificate expiry notify the ops topic. A checker that stops reporting also alarms. | A single vantage point inside AWS. It says nothing about users elsewhere. |
| `backup-verify/` | shared-services | The retained landing bucket (`lz-landing-<account>-<region>`): versioned, KMS-encrypted, TLS-only, never public, tiered to cold storage, nothing expires by default. `prevent_destroy` on the bucket and its key keeps hourly teardowns and a stray destroy from removing it. A daily Lambda reports the age of the newest object and the object count. A synthetic heartbeat producer writes one tiny object under `heartbeat/` every 6 hours (expired after 7 days), so the check has something to measure. The stale alarm is **off** until the 24-hour window holds only real readings (`freshness_alarm_enabled`). | Freshness only, and only once the alarm is on. The heartbeat is synthetic: it proves the check and the alarm, not that a real backup ran or can be restored. Restore verification is deferred. |
| `remediation/` | prod | A high-CPU alarm on a monitored instance reboots it behind a cooldown and a circuit breaker. See [ADR-0005](adr/0005-remediation-safety-model.md). | Disabled by default: `dry_run = true` and no monitored instances. The reboot, cooldown and circuit proofs forced the alarm. Real CPU load was shown to raise the alarm in dry run only, so no real reboot has followed real load. |

## How they connect

- `uptime/` and `backup-verify/` read `ops_topic_arn` from the observability
  state, so apply `observability/` first.
- `scripts/export-incident-inputs.py` adds their alarm names to the incident
  responder's known alarms when those roots are applied. The responder has no
  remediation for them, so they are notify-only: the alert and a short Amazon Nova
  Lite summary reach the inbox, and nothing acts automatically (proven 2026-10-17 for
  `uptime-monitor-site-down`, see [incident-response.md](incident-response.md)).
  Without this, the responder rejects them as unknown alarms.
- `remediation/` has its own topics and key. Its alarms have no alarm actions, so
  they never reach the ops topic or the responder.

## CI and tests

- `guardrails.yml` runs the shared static gates on all three roots, and a
  `python_tests` job runs `uptime/tests`, `backup-verify/tests` and
  `remediation/tests`. Locally: `make test-standing`.
- The teardown check looks for the hourly layers only, so these standing
  resources are not reported as leftovers, and nothing is excluded from it.
- The per-PR cost gate (`finops-gate.yml`, Infracost) is not wired to these three
  roots. Their total is a few dollars a month, so a threshold gate adds little.
  The CostCenter and tag policies still apply through the shared static jobs.

## Cost

An estimate from list prices, not yet checked against a bill: about **$5 to $5.50
a month**. Three customer-managed keys are about $3. Custom metrics are about
$1.50 (3 for uptime and 2 for backup, one dimension each). Four alarms are about
$0.40, plus $0.10 for each monitored instance added later. The heartbeat producer
adds four tiny writes a day. Lambda, EventBridge,
DynamoDB, logs (30-day retention) and S3 are pennies. DynamoDB items expire by
TTL: 90 days for uptime logs, twice the circuit window for remediation state.

## Live proof

Each claim is recorded separately, with isolated targets. Times are UTC, 2026-10-17.

| Claim | Result | Evidence |
| ----- | ------ | -------- |
| Uptime: a failing check raises the site-down alarm and notifies the ops topic | Proven | The check was pointed at a 404 path on the portfolio site (`/__uptime-proof-404`), so the site itself was never down. Two scheduled failures were recorded, and the alarm re-fired from them: "2 datapoints [0.0, 0.0] were less than the threshold (1.0)". The alarm history shows the ops-alarms topic action executed. The URL was then reverted and the alarm recovered to OK. |
| Uptime: a stopped or unmeasured check alarms (missing data is breaching) | Observed, not a clean proof | The first attempt pointed the alarm at a new URL dimension with no data, and it went to ALARM with "no datapoints were received for 2 periods". That shows missing data breaches, but it is not evidence that a failing check does. The proof above was redone after real datapoints existed. |
| Backup freshness: an empty bucket alarms | Proven | With the alarm temporarily enabled, the checker reported 0 objects at age 9999. The alarm reached ALARM about 90 seconds later and the ops-alarms topic action executed. The alarm was then turned off again. |
| Backup freshness: a producer can write to the bucket | Proven | The heartbeat Lambda wrote `heartbeat/2026/10/17/053645Z.json` at 05:36:46, SSE-KMS with the bucket key, and the checker then reported age 0.0. Its first scheduled run was denied by the `require-s3-encryption` SCP: it relied on the bucket default and sent no encryption header. The producer now sends the header, which is the guardrail working as designed. |
| Backup freshness: a stale object alarms | Not proven | The 24-hour alarm window still holds the 9999 datapoint from the empty-bucket check (last at 02:16), so the alarm stays off until after the 2026-10-18 08:00 check. Then: stays OK while the heartbeat runs, and alarms after it is paused (`heartbeat_enabled = false`) past `max_age_hours`. Covered by `backup-verify/tests` only until then. |
| Uptime alarm reaches the responder as notify-only | Proven | Separate session. `uptime-monitor-site-down` forced to ALARM at 06:36:40 (site not down). It reached n8n through ops-alarms, SQS and the relay. The runbook summarized, sent one notice and took no action: CloudTrail shows no remediation call from the remediate role. The alarm recovered to OK at 06:38:00 on the next check and the OK event triggered nothing. DLQ 0. The responder was destroyed afterwards. |
| Remediation: dry run sends a notice and reboots nothing | Proven | Forced alarm at 02:57 with `dry_run = true`. The Lambda logged `remediating` with `dry_run: true`, remediation-alerts published and delivered 1 message, the state table stayed empty, and CloudTrail has no RebootInstances event for it. |
| Remediation: a forced alarm reboots a monitored instance | Proven | Forced alarm at 03:00 with `dry_run = false`. The Lambda logged `remediating` with `dry_run: false`, one attempt was written to the state table (version 1), and CloudTrail recorded RebootInstances from the `remediation-reboot` session at 03:00:00. |
| Remediation: a second alarm inside the cooldown is skipped | Proven | Forced again about a minute later: `skipped`, reason `cooldown` (900 s). The state item did not change. |
| Remediation: an instance without `Monitored=true` is left alone | Proven | Tag removed, alarm forced: `skipped`, reason `not_monitored`. The tag was restored afterwards. |
| Remediation: three attempts open the circuit and page on-call once | Proven | State item cleared, cooldown set to 1 s, alarm forced 5 times about 20 s apart. Forces 1 to 3 rebooted the instance (CloudTrail at 03:03:18, 03:03:37, 03:03:58). Force 4 returned `escalated`, `circuit_open`, `paged: true`. Force 5 returned `paged: false`. remediation-oncall published and delivered exactly 1 message. |
| Remediation: real CPU load triggers the alarm | Proven (dry run) | Separate run on a fresh instance. A busy loop on each vCPU was started through SSM send-command at 03:28 and nothing was forced. At 03:36:31 the alarm went from OK to ALARM on its own: "2 datapoints [99.99, 99.995] were greater than or equal to the threshold (80.0)". The Lambda received the event at 03:36:31 and logged `remediating` with `dry_run: true`. remediation-alerts published 1 and delivered 1 (0 failed), remediation-oncall published nothing, the state table stayed empty, and CloudTrail has no RebootInstances event since 03:30. RemediationSuccess 1, TimeToRemediateMs about 2.9 s. |

Metrics for the forced-alarm instance matched the logs: RemediationSuccess 5 (1 dry run, 4
reboots), RemediationSkipped 1 (the cooldown; the `not_monitored` skip emits no
metric), EscalationTriggered 1, EscalationSuppressed 1, and TimeToRemediateMs
averaged about 2.4 s from alarm to action. At the time RemediationSuccess also
counted dry runs, so on its own it could not tell a drill from a reboot. It now
carries a `DryRun` dimension (`true` or `false`) alongside `Action` and
`ResourceId`, so reboots can be counted alone. The proofs above predate it, so
their datapoints sit in the old two-dimension series. The other metrics keep their
two dimensions.

The proof instance was a t3.nano running AL2023 x86_64, in the prod default VPC
with no public IP, IMDSv2 required and an encrypted root volume. An arm64 launch
was refused first with `InvalidAMIID.NotFound`: the Workloads EC2 baseline allows
only `al2023-ami-*-x86_64` images, so prod cannot see arm64 AMIs at all. The
guardrail behaved as designed. The instance was terminated afterwards, leaving
prod with no instances.

The CPU-load instance was a second t3.nano (AL2023 x86_64, IMDSv2 required,
encrypted gp3 root, `Monitored=true`) with a temporary instance profile carrying
only AmazonSSMManagedInstanceCore. It reached SSM through a public IP in the
default VPC, behind a temporary security group with no inbound rules, so nothing
could connect to it. T3 credits are unlimited by default, so the sustained load
was not throttled. The burner was wrapped in `timeout` so it would stop on its
own. Afterwards the instance was terminated and the security group, role and
instance profile were deleted.

Each proof changed a live setting temporarily and was reverted. The remediation
overrides were passed as `-var` flags only, never committed. Afterwards the alarm
was removed, the Lambda was back to `dry_run = true` with a 900 s cooldown, the
state table was empty, and all three roots planned empty (no drift).
