# Incident response in the landing zone

Two existing projects run here as landing-zone controls instead of standalone demos:
[aws-incident-forensics](https://github.com/jordann6/aws-incident-forensics) (the
containment and evidence runbook) and
[aws-incident-responder](https://github.com/jordann6/aws-incident-responder) (an n8n
remediation workflow). The `incident/` root wires them to the org's findings and alarms.

Status: deployed, proven and torn down on 2026-10-06. Forensics (security account) stays
up as a standing control. The responder is hourly and was destroyed. One piece is built
but **unproven**: the Claude-written incident summary (see
[Claude summary](#claude-summary-built-not-proven)).

## Shape

| Piece | Account | Lifecycle |
|---|---|---|
| Forensics runbook (Step Functions, per-step roles, evidence bucket, evidence KMS key) | security | standing |
| Org finding routing (GuardDuty to cross-account bus to runbook starter) | security, prod | standing |
| Incident alarm reader role | shared-services | standing |
| n8n image mirror (ECR, pinned by digest) | prod | standing, tiny |
| Responder (private n8n on Fargate, relay Lambdas, SQS, DLQ) | prod | hourly, destroyed after proof |
| Notices | ops-alarms and security-findings SNS topics, email only | standing |

No Slack. Notices go to the ops-alarms email topic. Both topics had no subscription at
all before this work: `alert_email` had never been set, so alarms fired into nothing.
The plan now adds the email subscriptions (each needs its confirm link clicked).

The responder runs in the prod VPC's private app subnets. There is no internet route
there. AWS APIs go through the VPC endpoints, and the rest (Lambda, RDS and Bedrock
APIs) goes through the hub firewall's default-deny domain allowlist. The only firewall
change was allowing the one Bedrock hostname.

### Why Trivy flags two CRITICAL findings (AWS-0104)

The responder's remediation and n8n security groups carry `0.0.0.0/0` egress. A security
group cannot name a domain, so this is the shape that lets traffic reach the firewall,
which holds the real control: default deny with an exact-domain allowlist, and no
internet gateway route in the VPC. The finding is real in isolation and accepted here
with that compensating control. It is not a hole in the VPC.

## What was proven

| # | Proof | Result |
|---|---|---|
| 1 | Prod GuardDuty sample finding to cross-account bus to runbook starter | Pass. Execution succeeded at `NoActionNeeded` (`should_respond` false: the instance in the sample no longer exists) |
| 2 | Drill: isolate a prod instance, capture evidence | Pass on the second run, about 2 minutes (see bugs). Quarantine security group and tags, session revocation deny, encrypted snapshot copy under the evidence key, manifest in the evidence bucket |
| 3 | Forced alarm to SQS to relay to n8n to remediate x3 to RDS failover | Pass. Failover started 22:09:08 and completed 22:09:43, alarm back to OK 22:09:52, DLQ 0. A control run with the alarm forced OK triggered no remediation |
| 4 | Static and policy gates | Pass: fmt, validate, tflint, checkov 0 failed, conftest 34/34 per root, gitleaks, shellcheck, unit tests |

## Bugs the live run found

Both are real defects that unit tests and plans could not catch.

1. **Evidence step ran before the snapshot finished.** The runbook encrypted the source
   snapshot while it was still `pending`, and EC2 answered "Source snapshot is not
   complete". Containment had already worked, so the first drill failed only at evidence.
   Fix: a `SnapshotNotReady` retry (20 seconds, up to 45 attempts) in the forensics
   runbook.
2. **The EBS-encryption SCP made a resource undestroyable.** `require-encrypted-ebs`
   (on the Workloads OU) denies `ec2:DisableEbsEncryptionByDefault`, so destroying
   `aws_ebs_encryption_by_default` in the workload root failed. Teardown had to remove it
   from state by hand. Fix: the resource was dropped from the workload root, because the
   Workloads declarative policy already owns the setting.

Smaller findings:

- The n8n invoke policy allowed the unqualified Lambda ARN, but the workflow invokes a
  qualified one (`:$LATEST`), which returned 403. The policy now allows the ARN and the
  ARN with `:*`.
- A Lambda in a VPC holds its network interface after deletion, so the responder's
  security group took about 21 minutes to destroy. Plan teardown around it.
- The forensics clean script also deletes the drill's encrypted copy, which lives in the
  prod account. Only the manifest in the evidence bucket remains.

## Claude summary: built, not proven

The workflow can ask Claude in Amazon Bedrock for a plain-English incident summary,
in-region, so the region-lockdown SCP did not need a change. It is **not proven**.
Bedrock returned 403 "not available for this account" for two models and 404 for two
others, an account entitlement problem with no CLI path to fix. The proof ran with
template summaries. `claude_model` defaults to an empty string, which skips the call.
No result here should be read as a Claude-generated summary.

## Standing cost

The standing pieces are a few dollars a month (forensics, scanner, queues, KMS). The
responder run, including a Multi-AZ failover, was part of one compute-baseline session.
