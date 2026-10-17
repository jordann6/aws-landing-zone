# Standing controls: uptime, backup freshness, remediation

Three small roots that stay deployed. Status: **merged and statically validated
only. Not yet deployed or demonstrated.** Nothing here has been applied, so no
result below is a live result.

| Root | Account | What it does | What it does not prove |
| ---- | ------- | ------------ | ---------------------- |
| `uptime/` | shared-services | A Lambda checks jordandesigns.io every 5 minutes (status, optional body text, certificate days left, one retry) and writes metrics and a log row. Alarms for site down, high latency and certificate expiry notify the ops topic. A checker that stops reporting also alarms. | A single vantage point inside AWS. It says nothing about users elsewhere. |
| `backup-verify/` | shared-services | The retained landing bucket (`lz-landing-<account>-<region>`): versioned, KMS-encrypted, TLS-only, never public, tiered to cold storage, nothing expires by default. `prevent_destroy` on the bucket and its key keeps hourly teardowns and a stray destroy from removing it. A daily Lambda reports the age of the newest object and the object count. The stale alarm is **off** until a producer writes here (`freshness_alarm_enabled`), because cold data would alarm forever. | Freshness only, and only once the alarm is on. Nothing writes to the bucket yet and no prefix or producer is defined. It does not show a backup completed or can be restored. Restore verification is deferred. |
| `remediation/` | prod | A high-CPU alarm on a monitored instance reboots it behind a cooldown and a circuit breaker. See [ADR-0005](adr/0005-remediation-safety-model.md). | Disabled by default: `dry_run = true` and no monitored instances. A forced alarm proves the response path, not that real CPU load triggers it. |

## How they connect

- `uptime/` and `backup-verify/` read `ops_topic_arn` from the observability
  state, so apply `observability/` first.
- `scripts/export-incident-inputs.py` adds their alarm names to the incident
  responder's known alarms when those roots are applied. The responder has no
  remediation for them, so they are notify-only: the alert and the Claude summary
  (once Bedrock access works) reach the inbox, and nothing acts automatically.
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
$0.40, plus $0.10 for each monitored instance added later. Lambda, EventBridge,
DynamoDB, logs (30-day retention) and S3 are pennies. DynamoDB items expire by
TTL: 90 days for uptime logs, twice the circuit window for remediation state.

## Live proof (not done)

Each claim is recorded separately, with isolated targets:

1. Uptime: a controlled failing endpoint, never the portfolio site.
2. Backup freshness: a dedicated test prefix or fixture object.
3. Remediation: a disposable instance with explicit approval for interruption,
   first with `dry_run = true`. A forced alarm and real CPU load are separate claims.
