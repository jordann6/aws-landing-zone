# Standing controls: uptime, backup freshness, remediation

Three small roots that stay deployed. Status: **deployed on 2026-10-16 and smoke
checked. The uptime and backup failure proofs ran on 2026-10-17 (see Live proof).
The remediation proofs are not done.** Each root was applied from a saved
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

## Live proof

Each claim is recorded separately, with isolated targets. Times are UTC, 2026-10-17.

| Claim | Result | Evidence |
| ----- | ------ | -------- |
| Uptime: a failing check raises the site-down alarm and notifies the ops topic | Proven | The check was pointed at a 404 path on the portfolio site (`/__uptime-proof-404`), so the site itself was never down. Two scheduled failures were recorded, and the alarm re-fired from them: "2 datapoints [0.0, 0.0] were less than the threshold (1.0)". The alarm history shows the ops-alarms topic action executed. The URL was then reverted and the alarm recovered to OK. |
| Uptime: a stopped or unmeasured check alarms (missing data is breaching) | Observed, not a clean proof | The first attempt pointed the alarm at a new URL dimension with no data, and it went to ALARM with "no datapoints were received for 2 periods". That shows missing data breaches, but it is not evidence that a failing check does. The proof above was redone after real datapoints existed. |
| Backup freshness: an empty bucket alarms | Proven | With the alarm temporarily enabled, the checker reported 0 objects at age 9999. The alarm reached ALARM about 90 seconds later and the ops-alarms topic action executed. The alarm was then turned off again. |
| Backup freshness: a stale object alarms | Not proven | The 24-hour alarm window still held the 9999 datapoint from the empty-bucket check, so an aged object could not be shown on its own. Covered by `backup-verify/tests` only. Prove it once a producer writes to the bucket. |
| Remediation: dry run, real reboot, cooldown, unmonitored skip, circuit breaker | Not run | Needs a disposable tagged instance in prod. Covered by the 14 unit tests only. |
| Remediation: real CPU load triggers the alarm | Not run | Needs SSM access on the instance. A forced alarm proves the response path, not this. |

Each proof changed a live setting temporarily and was reverted. After the uptime
and backup proofs both roots planned empty (no drift).

### Remaining proof plan

Remediation, on a disposable instance with explicit approval for interruption,
first with `dry_run = true`:

1. Forced alarm in dry run: a notice is sent and nothing is rebooted.
2. Forced alarm with `dry_run = false`: the instance is rebooted.
3. A second forced alarm inside the cooldown is skipped.
4. An instance without `Monitored=true` is left alone.
5. Three attempts open the circuit, and one on-call page is sent.
