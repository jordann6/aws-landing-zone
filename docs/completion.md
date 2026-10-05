# AWS landing-zone completion

The completion scope is the persistent organization, accounts and guardrails,
base governance, observability, shared inspection network, and the private EKS
and Multi-AZ PostgreSQL reference workload. LLM gateway integration is cancelled.
No provider keys, container publication, Fargate service, or provider demo is
required to finish this infrastructure scope. The standalone gateway checkout
and Phase B changes remain preserved for separate work.

## Verified infrastructure

Before teardown, live checks confirmed EKS 1.35 and its two-node AL2023 managed
group were ACTIVE, PostgreSQL 16.14 was available, encrypted, private and Multi-AZ,
and private endpoints were available. Prod used the intended TGW spoke egress
association and inspection return propagation. Network Firewall was READY and
IN_SYNC, RAM associations were ASSOCIATED and prod could see the shared TGW.
Current checks confirm all member accounts remain ACTIVE and persistent RAM
organization onboarding remains enabled.

This proves infrastructure metadata and routing configuration. It does not
claim forced RDS failover timing, a deployed application, or an end-to-end
firewall traffic test. Cross-region backup is disabled until a destination region
is approved through governance. Existing Phase B scanner live proof and legacy
secret-history/key cleanup remain pending; they are not represented as completed.

Gateway-specific provider domains, output contracts and the DynamoDB endpoint
were removed from configuration. Generic HOME_NET, TGW routing, accepter fixes,
supported EKS/RDS versions, monitoring endpoint and RAM onboarding are retained.
Network source changes were not applied before hub teardown. Workload teardown
removed all deployed resources, including the dropped DynamoDB endpoint.
Preserve these changes for the final code review.

## Workload teardown complete

Workload state is empty. Live checks confirm no prod EKS cluster, nodes, RDS
instance or interface endpoints. The backup vault and app ECR repository are gone.
The initial 85-resource teardown removed 84 resources but timed out waiting for
Inspector disablement. A reviewed Inspector-only recovery succeeded and removed
the final resource. The saved workload destroy plan has already been applied and
must not be reused. No gateway resources were deployed.

## Network teardown complete

The operator authorized the exact saved network teardown command. Its reviewed
plan contained 50 deletions only and no account or permanent RAM onboarding
resources. Apply completed successfully with 50 destroyed, zero added and zero
changed. The saved network plan has already been applied and must not be reused.
Demo network log groups were removed with their owning root.

Final state and live API checks confirm both demo states are empty, with zero
demo EKS, RDS, nodes, interface endpoints, NAT gateways, Transit Gateways and
firewalls. The backup vault is absent, no gateway deployment exists, all member
accounts remain ACTIVE, and persistent RAM sharing remains enabled.

Separate retained-foundation checks confirm organization RAM trusted access and
its service-linked role, an actively logging organization trail, the shared-services
OAM sink, both prod/network source links and five central alarms. Accounts,
governance and observability states remain populated. Backend state is retained.

The demo hourly layers have been removed. Retained baseline services, KMS deletion
windows and storage can still incur charges. Billing reporting is delayed, so
live teardown verification does not establish a zero invoice. Recheck billing
once reporting catches up.

For future demos, state the projected hourly cost, deploy through reviewed saved
plans, record proof and tear down workload before network. Do not use general
`make destroy` for this completion path, since it also removes governance. Never
close or suspend member accounts. Preserve audit history, observability and RAM
organization onboarding.

Inspect recovery points before future workload teardown. During Vault Lock grace,
remove the lock configuration before deleting reviewed recovery points, verify
an empty vault and refresh the destroy plan. After compliance grace expires,
retain locked recovery points until retention ends and plan hourly resource
teardown around that blocker. Review published ECR images before cleanup.

## Verify and close out

The metadata-only live teardown verifier passed on this machine:

```bash
python3 /private/tmp/lz-finish-verify.py --expect-empty
python3 /private/tmp/lz-retained-foundation-verify.py
```

It checks state and live APIs for demo EKS, RDS, nodes, interface endpoints, NAT,
TGW and firewall resources; confirms no gateway deployment; and requires ACTIVE
accounts and persistent RAM sharing. It also requires the backup vault to be gone.
The metadata result is stored privately under `~/.config/landing-zone/`. Do not
claim teardown is complete if the verifier fails. Temporary scripts and plans
under `/private/tmp` must be recreated if unavailable.

Format, Terraform validation and local static security checks passed during
closeout; subsequent documentation diff and link checks also passed. Review the
final diff before publication. Commit, push and merge only when requested.
Preserve sibling Phase A/B work. Document deferred features and proof limits,
update the private handoff, and check billing after Cost Explorer data catches up.
Legacy gateway state-history cleanup is complete: 20 obsolete versions were
deleted and zero remain, with the latest clean state retained. Old-key retirement
and scanner live proof remain independent work; see
[the separate cleanup runbook](security-cleanup.md).

For future demos, export private account/network metadata using
`scripts/prepare-workload-inputs.py`, with `--workload` after network deployment.
The old exporter filename remains a compatibility entry point. Future plans
no longer publish gateway contracts or allow provider API domains by default.
