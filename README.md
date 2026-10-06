# AWS Landing Zone

**Compute baseline status:** queued after Azure and GCP. New IMDSv2 and EBS
encryption SCPs plus an EC2 declarative policy will first be planned for the
Sandbox OU. The operator applies governance before a reduced workload network
or compute deployment. A private SSM management VM from this zone's golden AMI
and its live guest-hardening proof are pending. Existing verification below
covers the earlier EKS/RDS and network demo.

The public repository is
[jordann6/aws-landing-zone](https://github.com/jordann6/aws-landing-zone).
Historical Terraform state keys and resource tags keep their internal names;
renaming those requires a separate migration plan.

A Terraform AWS landing zone with a persistent multi-account organization,
inherited guardrails, centralized audit and security controls, and an inspected
private workload network. The reference workload is private EKS and Multi-AZ
PostgreSQL. Application integration is outside the completion scope.

![AWS landing-zone architecture and resource lifecycle](docs/architecture.png)

The diagram shows the infrastructure design and configured relationships, not a
running application or proof of traffic. Blue clusters are retained foundations;
orange clusters are temporary network and workload layers. Dev, test and sandbox
accounts exist without deployed spoke VPCs. Cross-region backup is disabled.

## Current status and remaining work

Before teardown, Phase C verification recorded **50 network resources and 85
workload resources deployed** in `us-east-1`. Network Firewall was READY and
IN_SYNC, both RAM associations were ASSOCIATED, and prod could see the shared
Transit Gateway.
EKS 1.35 and its two-node AL2023 group were ACTIVE. PostgreSQL 16.14 was available,
private, encrypted and Multi-AZ. Private endpoints and TGW routing were verified.
These checks establish infrastructure state and configuration; forced database
failover and end-to-end firewall traffic have not been demonstrated.

**Workload teardown is complete.** Live checks confirm zero workload state
resources, EKS clusters, nodes, RDS instances and prod interface endpoints, with
the backup vault and app repository gone. The initial apply removed 84 resources
but timed out disabling Inspector; an Inspector-only recovery removed the final
resource. The diagram above records the demonstrated design, not current live
workload inventory.

**Network teardown is complete:** all 50 managed resources were destroyed.
Final state and live API checks confirm zero demo EKS, RDS, nodes, interface
endpoints, NAT gateways, Transit Gateways and firewalls. Both demo states are
empty and the backup vault is gone. All member accounts remain ACTIVE;
organization RAM onboarding, governance, observability and backend state are
retained. CloudTrail is logging, and the OAM sink, both source links and five
central alarms remain present.

The demonstrated hourly layers have been removed. Retained baseline services,
KMS deletion windows and storage can still generate charges; check billing after
reporting catches up. Review the final source diff and preserve sibling Phase A/B
work. Follow the [completion runbook](docs/completion.md) for verification and
future demo lifecycle guidance. Commit, push and merge only when requested.

LLM gateway integration is cancelled and was never deployed. Its checkout and
Phase B work remain preserved separately. Provider domains and gateway output
contracts have been removed from configuration. Network allowlist edits were not
applied before the hub was removed; workload integration resources have also
been removed. Legacy state-history cleanup is complete: 20 obsolete gateway
versions were deleted and the latest clean state retained. Phase B scanner live
verification and old-key retirement remain separate unfinished work.

## Account and policy boundaries

Security, Infrastructure, Workloads and Sandbox OUs contain eight member accounts:
security, network, shared-services, log-archive, dev, test, prod and sandbox.
SCPs deny root use, leaving the organization, unapproved regions, public or
unencrypted S3, and disabling detective services. The organization also supplies
a tag policy. Member accounts inherit the applicable controls; the management
account is exempt from SCPs and needs its own hardening.

Accounts carry `close_on_deletion = false` and `prevent_destroy`. Never close or
suspend them as part of a demo teardown. Organizations, OUs, SCPs and idle accounts
have no direct service fee; resources retained in those accounts can still bill.
Permanent RAM organization onboarding lives in the accounts root, so destroying
the network does not disable sharing for future demos.

## Terraform layers

| Root | Purpose | Lifecycle |
|---|---|---|
| `accounts/` | Organization, OUs, accounts, SCPs, tag policy and RAM organization onboarding | Permanent |
| `terraform/` | Audit, detective controls, identity and budgets | Retained baseline |
| `observability/` | CloudWatch OAM links, central alarms and security findings routing | Retained baseline |
| `network/` | Shared TGW, inspection VPC, firewall, NAT, endpoints and network logs | Temporary, hourly billing |
| `workload/` | Private prod VPC, EKS, RDS, backup and image supply resources | Temporary, hourly billing |

Phase A observability is included in this repository. Its shared-services
CloudWatch OAM sink, prod/network links, central alarms and security findings
routing are retained. The workload includes the Container Insights add-on and
IRSA configuration for a future operator-reviewed deployment; that add-on was
not part of the completed Phase C demo.

### Governance

| Control | Implementation |
|---|---|
| Audit | Organization CloudTrail and Config delivery to encrypted S3; GOVERNANCE-mode Object Lock and trail validation |
| Detection | GuardDuty delegation; optional Security Hub CIS AWS Foundations 1.4.0 integration; AWS Config |
| Identity | Optional IAM Identity Center personas, permission boundaries and short sessions |
| Encryption | Customer-managed KMS keys with rotation and scoped service policies |
| Root use | Management password policy and EventBridge root-use alerting |
| Cost | Monthly budget; optional Cost Anomaly Detection monitor |

Optional integrations are controlled by Terraform variables. They must not be
reported as deployed merely because their definitions exist.

### Inspected network

The network account hosts the `10.0.0.0/16` inspection VPC. RAM shares the Transit
Gateway with the organization; prod attaches through explicit acceptance. Separate
spoke and inspection route tables route internet egress and return traffic through
Network Firewall and the hub NAT. The demo inspection path uses one availability
zone and is not a production availability design.

The source allowlist now defaults to AWS and Cognito domains. The prod source CIDR
is included in firewall HOME_NET. Hub interface endpoints, an S3 gateway endpoint,
VPC flow logs and firewall flow/alert logs support private access and investigation.

### Private reference workload

| Component | Implementation |
|---|---|
| VPC | `10.3.0.0/16`, private subnets, no local IGW or NAT; TGW inspection route |
| Access | Prod's own interface endpoints for ECR, STS, EC2, ELB, Logs, Monitoring, EKS, SSM and Secrets Manager; S3 gateway endpoint |
| EKS | Private API, encrypted secrets, IRSA and two AL2023 managed nodes |
| PostgreSQL | Encrypted private Multi-AZ RDS with a managed secret; app-to-DB security group access on port 5432 and data subnet NACL |
| Backup | Daily local AWS Backup and Vault Lock with a demo grace period; cross-region copy requires explicit region approval and opt-in |
| Supply chain | Immutable ECR tags, scanning, pull-through cache, Inspector and an on-demand Image Builder pipeline |

The deployed node group uses the standard AL2023 EKS image. The Image Builder
pipeline does not establish that a custom image was built or used. No application
has been deployed to prove the permitted app-to-database path.

## Plan, prove and tear down

The assistant runs formatting, validation, saved plans and read-only verification.
The operator reviews and runs applies and destroys. For future demos, the private
input exporter reads existing account and network state:

```bash
python3 scripts/prepare-workload-inputs.py --workload
terraform -chdir=workload fmt -check
terraform -chdir=workload validate
terraform -chdir=workload plan -var-file=phase-c.tfvars.json -out=tfplan -input=false
terraform -chdir=workload show tfplan
```

The exporter requires the deployed network. Generated inputs, state and saved
plans stay private and gitignored. Its previous filename remains a compatibility
entry point. A saved plan must match the intended operation and current state
before an operator applies it.

Guardrail verification scripts check the organization structure, logging and
selected live deny behavior. They do not measure RDS failover or prove application
traffic. The state-based `scripts/verify-teardown.sh` is a supplemental check;
completion requires live inventory checks too, as described in the runbook.

Destroy **workload first, network second**. Do not use general `make destroy` for
this completion path because it also removes governance and audit buckets. Retain
the audit history and observability foundation. An expired compliance lock with
recovery points can block backup deletion until retention ends. KMS deletion
windows, Secrets Manager recovery windows, retained storage and baseline services
can leave residual charges after the hourly layers are gone. Check billing after
the reporting data catches up.

## State backend

Every root keeps state in a dedicated bucket that `bootstrap/state_backend.tf`
owns ([ADR-0003](docs/adr/0003-dedicated-state-backend.md)), under
`aws-landing-zone/<root>.tfstate`.

| Control | Implementation |
|---|---|
| Cannot be deleted by a plan | `lifecycle { prevent_destroy = true }` on the bucket and the CMK |
| Recoverable history | Versioning; noncurrent versions expire only beyond the newest 20 and after 90 days; incomplete uploads abort after 7 days |
| Encrypted under a key this repo controls | SSE-KMS on a rotated CMK with bucket keys; every backend sets `kms_key_id`, and the bucket policy refuses SSE-S3 uploads |
| Never public, never plaintext in transit | All four public access blocks, `BucketOwnerEnforced`, and a bucket policy denying non-TLS and TLS below 1.2 |
| No concurrent writers | `use_lockfile = true` (S3 lock object, no DynamoDB table) |

The CI roles get the bucket prefix and the CMK only through S3
(`kms:ViaService`). Migration from the legacy shared bucket is
`scripts/migrate-state-backend.sh phase1|phase2`; it never deletes the legacy
objects.

## Validation and CI

CI runs the shared [platform-guardrails](https://github.com/jordann6/platform-guardrails)
static gates (gitleaks, fmt/validate, tflint, Checkov, Trivy, conftest OPA) on
the accounts, governance, network, workload, and observability roots. OPA checks
required tags and CostCenter. A repo-local Infracost workflow gates network,
workload, and observability changes at a $50/month increase, with an explicit
`cost-approved` PR label override. It runs before the PR report, rejects missing
cost estimates, and stores each root's report separately. Hosted Infracost
policy enforcement is disabled because its example tagging rules conflict with
the organization's tag policy. Pricing estimates still use the Infracost API.

The OIDC plan job and scheduled TTL trigger are currently disabled. Apply and
destroy workflows are available by manual dispatch; local credentialed applies
and destroys are run by the operator using reviewed, saved plans.

## Documentation

- [Completion runbook](docs/completion.md): completed teardown, verification and closeout steps.
- [Separate security cleanup](docs/security-cleanup.md): retired state-history cleanup without redeploying the gateway.
- [CIS mapping](docs/cis-mapping.md): controls mapped to resources and policies, with scope limitations.
- [Access model](docs/access-model.md): personas, account scope and permissions.
- [Data tier](docs/data-tier.md): segmentation, backup policy and availability design; proof limits are explicit.
- [State backend decision](docs/adr/0003-dedicated-state-backend.md): dedicated, KMS-encrypted backend instead of the shared bucket.
- [Architecture decision](docs/accelerator-vs-bespoke.md): bespoke Terraform versus Control Tower and Landing Zone Accelerator.
- [Diagram source](docs/diagram.py): official AWS icons via the mingrammer `diagrams` library. Regenerate with `python3 docs/diagram.py` after installing `diagrams` and Graphviz.
