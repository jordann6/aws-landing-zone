# AWS Landing Zone

A standalone, best-practice AWS landing zone built from bespoke Terraform: a
multi-account AWS Organization with preventive guardrails, centralized logging
and detective controls, federated human identity, and a centralized egress
inspection network. It deploys, proves its own guardrails, and destroys back to a
near-zero footprint.

![Architecture](docs/architecture.png)

## The problem it solves

A single AWS account with good intentions drifts. Someone turns off CloudTrail to
quiet an alarm, a bucket goes public for a quick test and stays that way, a
forgotten NAT gateway bills for a year, and the blast radius of one leaked
credential is everything. This zone is the opposite posture: separate accounts
per environment, guardrails applied at the org so they are inherited and cannot
be turned off from inside a workload, one immutable place all the logs land, and
one path to the internet that is inspected. The controls are preventive where a
deny is possible, not just detective.

## How AWS differs from the Azure and GCP zones

All three zones build to the same design. The parts specific to AWS:

- Isolation is by **account**, and the boundary is enforced by **SCPs** attached
  to OUs, so a member account cannot escape a control by acting locally. Azure
  uses Azure Policy at management-group scope; GCP uses org policies at the
  folder or org root.
- The management account is **SCP-exempt by design**, so the guardrails are
  attached below it and root hardening on the management account is a separate,
  documented step.
- Centralized egress runs through a **Transit Gateway** and an inspection VPC
  with **AWS Network Firewall**, shared to the org over RAM. Azure forces egress
  through Azure Firewall with a UDR; GCP uses hierarchical firewall policies and
  Cloud NAT.
- Admin access is **SSM Session Manager** over interface endpoints. There is no
  bastion and no public SSH.

## What gets built

Two Terraform roots. The governance root is nearly free and always on; the
network root is the hourly-billed inspection layer, kept separate so it comes up
only for its demo and is destroyed on its own.

### Governance root (`terraform/`)

| Pillar | Resources | Why |
|---|---|---|
| Hierarchy | Security, Infrastructure, Workloads (Dev/Test/Prod), Sandbox OUs; security, network, shared-services, log-archive, test accounts | Separate accounts are the real isolation boundary; Prod sits under stricter inherited policy |
| Guardrails | SCPs (deny root, deny leave-org, region lockdown, require S3 encryption, deny public S3, deny disabling detective services); org tag policy | Preventive, inherited, and unturnoffable from inside a workload |
| Logging | Org CloudTrail to an Object-Lock (WORM) S3 bucket in log-archive, KMS-encrypted, log-file validation | One immutable record of what happened, safe from the account that generated it |
| Detective | GuardDuty + Security Hub (CIS AWS Foundations 1.4.0) + AWS Config, delegated to the security account | Security operations run outside the account that can change the org |
| Encryption | KMS CMK with rotation, key policy scoped to the CloudTrail/Config services | One key family controls the whole audit record |
| Identity | IAM Identity Center personas (admin, platform-eng, junior-eng, manager, finops, security, break-glass) with permissions boundaries and short sessions | No IAM users; access is a group membership and a short session, no standing prod write |
| Root hardening | Strict password policy; EventBridge alarm on any root use | The account nobody should log in with cannot be used quietly |
| Cost | Monthly budget + Cost Anomaly Detection | Catches a forgotten hourly resource before the invoice does |

### Network root (`network/`)

| Pillar | Resources | Why |
|---|---|---|
| Connectivity | Transit Gateway, RAM-shared to the org, explicit attachment acceptance | Spokes attach to reach the internet; no auto-join |
| Inspection | Egress VPC, AWS Network Firewall (domain-allowlist default-deny), NAT, routing that forces egress and return through the firewall | Nothing reaches the internet without passing the firewall; the default-deny is what will enforce the pull-through cache |
| Private access | Interface endpoints (SSM, ECR, Secrets Manager, Logs) + S3 gateway endpoint | Registry, secrets, and logging over private IPs; SSM gives admin access with no bastion |
| Telemetry | VPC flow logs, firewall flow and alert logs to CloudWatch | A record of what traversed the hub |

## Deploy, test, destroy

The credentialed operations run through the reviewer-gated CI (see the ADRs) or
locally with admin credentials:

```bash
make deploy    # governance root, then the hourly network root (asks before the billing layer)
make test      # proves the guardrails DENY, not just that apply succeeded
make destroy   # tears both roots down, then verifies nothing hourly survives
```

- `make deploy` applies the governance root, then feeds its `network_account_id`
  and `organization_arn` outputs into the network root.
- `make test` runs `scripts/validate.sh` (the OU/SCP structure and live deny
  checks: region lockdown, CloudTrail tampering, management exemption) and
  `scripts/test-guardrails.sh` (org trail is logging, GuardDuty admin is the
  security account, and disabling Config or GuardDuty in a workload returns
  AccessDenied under the SCP).
- `make destroy` destroys the network root, empties the Object-Lock buckets with
  a governance-retention bypass, destroys the governance root, then runs
  `scripts/verify-teardown.sh` to fail if any hourly resource remains.

## Cost and teardown traps

The guardrail and topology layer is nearly free. The cost risk is a forgotten
hourly resource, which is exactly what the TTL guard and `verify-teardown.sh`
exist to catch.

| | Cost |
|---|---|
| Standing after destroy | ~$1 to $3/mo (KMS keys only, during their deletion window) |
| Demo window (deploy, demo, destroy) | a few dollars, driven by NAT + Network Firewall while up |

Teardown traps this repo handles:

- **Object-Lock buckets.** The trail and config buckets use GOVERNANCE-mode WORM,
  so `force_destroy` alone cannot empty them. `scripts/empty-locked-buckets.sh`
  deletes each version with `--bypass-governance-retention` before the destroy.
- **Order.** The network root is destroyed before the governance root, so the TGW
  and inspection VPC release cleanly.
- **What is allowed to remain.** A KMS key pending deletion (~$1/mo until its
  window closes) is the only thing left standing, by design.

## Documentation

- [docs/cis-mapping.md](docs/cis-mapping.md): CIS AWS Foundations control IDs
  mapped to the exact Terraform resource or policy, with honest N/A rows.
- [docs/access-model.md](docs/access-model.md): the persona-by-scope matrix and
  the CIS control each row satisfies.
- [docs/accelerator-vs-bespoke.md](docs/accelerator-vs-bespoke.md): why this is
  hand-written Terraform rather than Control Tower or the Landing Zone Accelerator.

## Pipeline

CI runs the shared [platform-guardrails](https://github.com/jordann6/platform-guardrails)
reusable workflows: credential-free static gates (gitleaks, fmt/validate,
tflint, Checkov, Trivy, conftest OPA) on both roots, an OIDC-authenticated plan
with a destroy guard, a reviewer-gated apply, and a scheduled TTL guard that
alarms if an hourly resource is ever left standing.
