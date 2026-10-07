# Phase D: us-west-2 warm standby, design and cost gate

Status: Option B built, proven and destroyed on 2026-10-07. See [Result](#result). The rest of this
document is the design and cost gate as approved.

## Recommendation

Build the scoped option (B), not the full mirror (A). B proves the part of DR that is hard and
interesting (encrypted cross-region replica, multi-region KMS, health-checked DNS failover,
automated promotion under the org guardrails) for about a third of the cost. A adds a second
hub and firewall that prove nothing B does not, and its cost is dominated by hourly network
plumbing. A stays documented as designed, not built.

## What the org does to us in us-west-2

| Control | Effect on us-west-2 | Action |
|---|---|---|
| region-lockdown SCP (accounts/scps.tf, `allowed_regions` default `["us-east-1"]`) | Denies every regional API in us-west-2 for Infrastructure, Sandbox and Workloads OUs. Global services (iam, route53, sts, organizations, cloudfront, waf) are exempt. | Add `us-west-2` to `allowed_regions`. This is an accounts-root change, persistent, applied by Jordan. It widens the whole org, so it is the one irreversible-feeling step. Recommend scoping: attach a second, narrower statement allowing us-west-2 only to the prod account principal, or accept org-wide and revert after the proof. |
| Workloads declarative policy and SCPs | Apply in every region. `require-encrypted-ebs` denies `ec2:DisableEbsEncryptionByDefault`. | Nothing new may manage `aws_ebs_encryption_by_default`. The declarative policy already enforces it in us-west-2. |
| Org trail, GuardDuty, Config, Security Hub | Multi-region features are only on if configured for it. | Check whether the delegated admins cover us-west-2. If not, standby is unmonitored for the proof window. State this in the docs, do not claim coverage. |
| KMS | A multi-region key is a distinct resource per region. | New primary key (multi-region) replaces `prod-data-cmk` for the replica path, or a new multi-region key is used for the replica only. Cannot convert an existing key. |

Decided: `aws_ebs_encryption_by_default.this` was dropped from `workload/compute-defaults.tf`.
The declarative policy owns the setting, and the SCP made the resource undestroyable.

## Option B (recommended): data-tier warm standby

Reuses `~/projects/multi-region-failover-manager` (health check, failover routing, promote Lambda,
SNS) adapted to the landing zone.

Primary (us-east-1, prod account): existing workload root with `enable_eks = false`,
`enable_tgw = false` if the RDS path allows it (verify in plan), RDS Multi-AZ on a multi-region
CMK. No NAT or firewall needed just to host a replica source.

Standby (us-west-2, prod account), new root `standby/`:
- Minimal VPC, two private subnets, no NAT, no IGW (the failover manager module).
- Multi-region KMS replica key.
- Encrypted cross-region RDS read replica (single-AZ, db.t3.small).
- Failover Lambda (outside VPC, control-plane calls only) and SNS, in us-west-2 on purpose.
- Cross-region EventBridge forward from the us-east-1 health-check alarm.
- Route 53 failover record on a `failover.jordandesigns.io` subdomain, health check on the
  primary, ACM cert per region only if an HTTPS endpoint is served (skip if the proof uses
  `route53 test-dns-answer`, which cuts ACM and the delegation step).
- Standby read-only API (HTTP API + Lambda) to show 200 on read and 409 on write before
  promotion, 200 on write after.

Proof, one session: deploy primary RDS and replica (20 to 35 min), show replica lag, force the
health check to fail, observe DNS answer flip, Lambda promotes, replica becomes writable, SNS
notice. Then destroy standby, then primary.

Teardown traps to design for now:
- Promoted replica drifts from state: destroy, never re-apply (same as the manager README).
- AWS Backup Vault Lock 3-day window: do not put the standby copy in the locked vault. No
  cross-region backup copy in this phase (`enable_cross_region_backup` stays false).
- Lambda is outside the VPC, so no ENI release delay.
- Multi-region KMS: schedule deletion on both keys, 7 day window, expect them in verify-teardown.
- Secrets Manager replica secret: `recovery_window_in_days = 0`.
- verify-teardown extended to us-west-2: VPCs, RDS, KMS pending deletion, Lambda, log groups,
  Route 53 health check and records, EventBridge rules.

### Cost (us-east-1 and us-west-2 rates are near identical)

| Item | $/hr |
|---|---|
| Primary RDS Multi-AZ db.t3.small + 20 GB gp3 | ~0.09 |
| Replica RDS db.t3.small + 20 GB gp3 | ~0.04 |
| Cross-region replication transfer | ~0.00 at this volume |
| Interface endpoints, 2 regions, 1 AZ each, Secrets Manager only | ~0.02 |
| Route 53 health check (prorated), Lambda, SNS, EventBridge | ~0.01 |
| KMS, 2 multi-region keys | ~$2/month prorated, negligible |
| Total | ~0.16 |

A 3 hour session is under $1. Even with 6 hours (slow RDS create and delete) it is about $1.

## Option A (full mirror, designed, not built)

Second hub VPC with NAT and Network Firewall, TGW in us-west-2 with inter-region peering,
standby prod VPC, EKS with 1 node, RDS replica, multi-region KMS, Route 53 failover, ACM.

| Item | $/hr |
|---|---|
| us-west-2 NAT gateway | 0.045 |
| us-west-2 Network Firewall endpoint (1 AZ) | 0.395 |
| TGW attachments, hub + prod + peering both sides | ~0.25 |
| EKS control plane + 1 t3.medium | ~0.14 |
| Replica RDS | ~0.04 |
| Endpoints (ECR, STS, logs, SSM) | ~0.06 |
| Standby subtotal | ~0.93 |
| Primary stack it replicates from (EKS 2 nodes, hub, firewall, RDS Multi-AZ), as measured in earlier sessions | ~1.15 |
| Total | ~2.1 |

A 3.5 hour session is about $7.30, inside the $6 to $8 cap only if nothing goes wrong. RDS create
and delete alone are 30 to 55 minutes, TGW peering needs a cross-account/region accept, and
the Network Firewall is another 15 to 20 minutes each way, so a realistic run is 4 to 5 hours,
about $8.50 to $10.50. It would also add inter-region TGW routing through two firewalls that
this proof does not need.

## Decisions taken

1. Option B approved.
2. us-west-2 opened by a prod-only SCP exception (accounts root), not an org-wide add.
3. Proof uses `route53 test-dns-answer`, no ACM, no delegation.
4. `aws_ebs_encryption_by_default` dropped from the workload root.

## Result

Applied as saved plans (accounts SCP exception, then 75 standby resources), proven, then
destroyed (75 of 75) and the SCP closed again. `scripts/test-standby.sh` passed 8 of 8:

| Check | Result |
|---|---|
| Both regions healthy | Pass |
| Replica encrypted with the multi-region CMK replica in us-west-2 | Pass |
| Row written on the primary appears on the standby | Pass |
| Standby write while a replica | 409 |
| DNS answer while healthy | Primary |
| Primary broken, DNS answer | Flipped to us-west-2 |
| Health alarm crosses regions, Lambda promotes the replica | Pass, replica available as a standalone instance |
| Write on the standby after promotion | Accepted (201) |

Traffic shifted by DNS first. Promotion followed on its own clock, which is the design
point: stateless failover is a DNS feature, stateful failover needs orchestration.

What was not proven or not built: the full mirror (Option A), a real delegated subdomain
with ACM, cross-region backup copy, and failback. Failback is destroy and redeploy.
Promotion is one way, so the promoted replica is never re-applied.

### Lessons

- The region exception is two SCP statements: allow us-west-2 for everyone, then deny it
  to every account except prod. A single statement cannot express "this region, this
  account". Closing the region again is an accounts apply without `standby_region`.
- Closing the region also blocks the verification calls. Run `verify-teardown` before
  closing, or the script reports the region as SKIPPED. This run's us-west-2 evidence is
  Terraform's own 75 of 75 destroy and an empty state, not a live listing.
- A Lambda that logs after destroy can recreate its log group. `make clean-standby`
  removes any `lz-standby` groups in both regions.
- The multi-region KMS keys carry a 7 day deletion window in both regions.
