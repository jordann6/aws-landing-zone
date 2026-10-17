# ADR-0005: Safety model for automatic remediation

- **Status:** proposed (implemented and unit tested; not deployed, so not accepted)
- **Date:** 2026-10-16

## Context

The `remediation/` root runs a Lambda in the prod account that reboots an EC2
instance when its high-CPU alarm fires. An automatic action that can loop, race
with itself, or touch the wrong instance is worse than no automation. The
incident responder already owns RDS failover and EKS actions, so this root is
deliberately narrow and does not overlap it.

Constraints that bind: one operator, no on-call rotation to absorb a reboot loop,
a prod account that also holds the workload, and a Lambda that is invoked by
at-least-once event delivery.

## Decision

Reboot is the only permitted action, and it is limited by the rules below. Each
rule has a unit test in `remediation/tests/test_remediation.py`.

| Concern | Rule |
| ------- | ---- |
| Target eligibility | Only instances tagged `Monitored=true`. The Lambda checks the tag, and the IAM reboot permission carries the same tag condition, so a bug in one layer does not widen the other. |
| Event eligibility | Only `CloudWatch Alarm State Change` events whose alarm name starts with `remediate-cpu-` and that carry an `InstanceId` dimension. Anything else is skipped and logged. |
| Staleness | The alarm state is read again before acting. An event delivered after the alarm recovered does nothing. |
| Persisted limits | One DynamoDB item per instance and action holds recent attempts. Cooldown is 900 seconds. The circuit opens after 3 attempts in 3600 seconds. |
| Atomicity | Each attempt is reserved before acting with a conditional write on a version counter. Two invocations that read the same state cannot both proceed, and the loser is treated as a cooldown. |
| Failed reboots | A failed reboot still consumes an attempt, so a reboot that keeps failing opens the circuit instead of retrying forever. |
| Dry run | `dry_run` defaults to true. It reads state and reports the intended action, but writes no attempts and reboots nothing, so drills cannot use up the real budget. |
| Escalation | With the circuit open the Lambda stops acting and pages the on-call topic once per window. Later re-fires emit a suppressed metric only. |
| Operator recovery | Delete the instance's item from the state table to close the circuit, or wait for it to expire (twice the window). Set `dry_run = true` to stop all reboots without removing the root. |

## Alternatives rejected

| Option | Why not |
| ------ | ------- |
| Extend the incident responder with an EC2 reboot action | The responder is an hourly stack that is destroyed after each proof. A standing control cannot depend on it being up. |
| Unconditional reboot on any CPU alarm | One flapping alarm becomes a reboot loop with no limit and no page. |
| In-memory cooldown inside the Lambda | Lost on every cold start and invisible to concurrent invocations. |
| Reuse the ops topic for notices | Its key policy would have to trust this role first. Deferred, not rejected. |

## Consequences

- Real remediation stays disabled (`dry_run = true`, no monitored instances) until
  the live proof records each behavior separately: the response path with a
  forced alarm, real CPU load triggering the alarm, and the circuit opening.
- The state table, topics and key are a small standing cost in prod.
- Only reboot exists. A new action needs its own eligibility rule and tests.
