# Incident response in the landing zone

Two existing projects run here as landing-zone controls instead of standalone demos:
[aws-incident-forensics](https://github.com/jordann6/aws-incident-forensics) (the
containment and evidence runbook) and
[aws-incident-responder](https://github.com/jordann6/aws-incident-responder) (an n8n
remediation workflow). The `incident/` root wires them to the org's findings and alarms.

Status: deployed, proven and torn down on 2026-10-06. Forensics (security account) stays
up as a standing control. The responder is hourly and was destroyed. A second session on
2026-10-17 proved the notify-only path for the standing uptime alarms and the incident
summary, now written by Amazon Nova Lite (see [Incident summary](#incident-summary-amazon-nova-lite)),
then the responder was destroyed again.

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
APIs) goes through the hub firewall's default-deny domain allowlist. The summary call
goes to `bedrock-runtime.us-east-1.amazonaws.com`, which the existing `.amazonaws.com`
entry already covers. The `bedrock-mantle.us-east-1.api.aws` entry added for the earlier
Claude path is no longer used.

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
| 5 | Standing alarm, notify-only (2026-10-17) | Pass. `uptime-monitor-site-down` forced to ALARM in shared-services at 06:36:40 (the site was never down). ops-alarms to SQS to relay (n8n answered 200) to three remediate calls: summarize, notify, remediate. The remediate call took 1.5 ms and CloudTrail shows no RebootDBInstance, failover or UpdateNodegroupConfig from the remediate role. ops-alarms published 2 (the alarm and the notice), delivered 3, failed 0. DLQ 0 |
| 6 | Incident summary from a model in a real run (2026-10-17) | Pass. The same run's summarize step called Amazon Nova Lite: CloudTrail records one `Converse` from the remediate role at 06:36:44, and Bedrock metrics show 1 invocation, 99 output tokens, 0 client or server errors |
| 7 | Recovery event takes no action (2026-10-17) | Pass. The alarm returned to OK on its own at 06:38:00 on the next check. The OK notice was relayed (200) and n8n made no remediate call, since the runbook acts on ALARM only |

The 2026-10-17 session was torn down the same morning: the responder first (36
resources, 07:02, the security group again waited about 21 minutes on the Lambda's
network interface), then the gated destroy of delivery, workload and network (run
39012172571, done 07:40). `verify-teardown` came back clean, the standing roots plan
empty, and `HOURLY_STACK_ENABLED` is back to false.

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
- The 2026-10-17 session's first apply failed before changing anything: the shared
  `tf-apply` workflow (platform-guardrails v1.7.1) uploaded every root's saved plan under
  one artifact name, so the workload apply replayed the network plan ("Inconsistent
  dependency lock file", "Saved plan is stale"). v1.7.2 names the artifact per root.

## Incident summary: Amazon Nova Lite

The responder's summarize step asks a model on Amazon Bedrock for a short on-call note,
in-region, with IAM scoped to one foundation-model ARN. If the call fails or no model
is set (`summary_model = ""`), a plain template note is used, so the runbook never waits
on it.

It was first built for Claude and never worked here. On the Messages API endpoint
(bedrock-mantle) this account gets 403 "not available for this account" for Haiku 4.5,
even with the marketplace agreement accepted and after retries on 2026-10-17. Claude
on the standard bedrock-runtime endpoint needs a cross-region inference profile, which
routes to us-east-2 and is denied by the region-lockdown SCP. Rather than widen an
org-wide SCP, the summary moved to Amazon Nova Lite (`amazon.nova-lite-v1:0`), an
in-region on-demand model that needs no agreement. `summary_model` rejects inference
profile ids, so a profile cannot be configured by mistake.

Proven in a real run on 2026-10-17 (proof 6 above). Switching back to Claude is one
variable once the account can call it in-region.

## Standing cost

The standing pieces are a few dollars a month (forensics, scanner, queues, KMS). The
responder run, including a Multi-AZ failover, was part of one compute-baseline session.
