# Compute baseline

The same three-part baseline runs in all three landing zones: preventive
guardrails that deny a non-compliant instance, one shared hardening role baked
into a golden image, and a cloud-native patch service. Every zone also runs one
hardened management instance built from its golden image, with no public IP,
reachable only through the cloud's private access path.

> One hardening role, three image pipelines, three enforcement points: Azure
> Policy approved-image deny, GCP `compute.trustedImageProjects`, AWS Allowed AMIs.

**Status:** code and static gates are complete. Nothing in this layer is applied
yet. The accounts root (SCPs and declarative policy) is live and plans additively.
Tests are written but not yet run against AWS.

## 1. Preventive guardrails (accounts root, Sandbox OU first)

| Control | Implementation | Proof (`scripts/test-guardrails.sh`, free `--dry-run`) |
|---|---|---|
| IMDSv2 required at launch, no downgrade | SCP `require-imdsv2` | `run-instances --metadata-options HttpTokens=optional` is denied |
| No unencrypted EBS; default encryption cannot be disabled | SCP `require-encrypted-ebs` | `create-volume --no-encrypted` is denied |
| Allowed AMIs: Amazon AL2023 plus golden AMIs owned by prod | Declarative policy `sandbox-ec2-baseline` (`allowed_images_settings`) | Canonical Ubuntu AMI is denied; compliant AL2023 launch reaches `DryRunOperation` |
| IMDS defaults enforced (IMDSv2 required, hop limit 1), serial console off, AMI and snapshot public sharing blocked | Same declarative policy | `get-allowed-images-settings`, `get-instance-metadata-defaults` (tokens `required`, hop limit `1`) in sandbox |

Both SCPs exempt only the sandbox account's Identity Center break-glass role
(`breakglass:sandbox` assignment in the governance root). The rollout attaches to
the Sandbox OU only. Promotion to the Workloads OU is a separate reviewed change
after the sandbox proof passes. The golden AMI owner is already in the Allowed
AMIs criteria, so promotion will not block it.

Declarative policies apply to the account's EC2 service attributes, not to IAM.
They hold even against a principal that an SCP would exempt. That is why the
SCPs and the declarative policy layer on each other rather than duplicate.

The break-glass exemption therefore covers EBS encryption only in practice.
`http_tokens_enforced` and Allowed AMIs bind the break-glass role too, so it
cannot launch an IMDSv1 instance or a non-allowed AMI in sandbox. This is
deliberate: break-glass exists to recover access and state, not to run
non-compliant compute. Relaxing either control means editing the declarative
policy through a reviewed accounts plan.

## 2. Account defaults (workload root, prod account)

`workload/compute-defaults.tf`:

- `aws_ebs_encryption_by_default` plus `aws_ebs_default_kms_key` set to a
  dedicated `alias/prod-ebs` CMK with rotation. The key policy mirrors the
  AWS-managed `aws/ebs` key (any principal in the account, only through EC2). This
  covers the Auto Scaling and Image Builder service-linked roles without naming
  them, so it does not fail in an account where they do not exist yet.
- `aws_ec2_instance_metadata_defaults`: IMDSv2 required, hop limit 1.
- EKS node group launch template (`eks.tf`): IMDSv2 at hop limit 1 and a
  KMS-encrypted gp3 root. Nodes stay on the EKS-optimized AL2023 image, which EKS
  versions and patches with the control plane. The golden AMI is for standalone
  instances only.

## 3. Golden AMI (workload root, `imagebuilder.tf`)

```
AL2023 (SSM public parameter)
  -> Amazon STIG component (stig-build-linux-medium, x.x.x)
  -> cis-baseline component: dnf upgrade, cis_baseline role from S3, offline
  -> test phase on a NEW instance booted from the AMI: check-hardening.sh
  -> distribution: KMS-encrypted AMI, tagged, optionally shared to the org
  -> Inspector scan; lifecycle policy deprecates all but the newest, deletes beyond 3
```

- The role is the same `cis_baseline` role from `azure-vm-hardening`, at the
  same pinned tag (`v2.0.1`) the Azure and GCP pipelines bake. It runs offline:
  `make stage-role` packages the tag plus `community.general` 9.x, then uploads
  it to a private SSE-S3 bucket that the build role reads through the S3 gateway
  endpoint. The build has no internet path, and AL2023 package repos are also
  S3-backed.
- STIG runs first, then the role, so the role's settings win any overlap. These
  are the settings the shared test checks on all three clouds.
- fail2ban is gated to Debian in the role, since AL2023 does not package it.
  `check-hardening.sh` reports it as SKIP on AL2023.
- The build and test instances run in a private app subnet. They have IMDSv2 at
  hop limit 1, no inbound rules, and egress only to the VPC endpoints and the S3
  prefix list.

## 4. Patching (workload root, `ssm-patching.tf`)

- Default Host Management Configuration makes every IMDSv2 instance
  SSM-managed.
- Patch baseline `prod-al2023`: Critical and Important security updates are
  approved immediately. Medium and Low security and bugfix updates are approved
  after 7 days.
- Patch group `prod`, a daily `Scan` association (runs at creation, so a new
  instance reports compliance straight away), and a weekly `Install` on Sunday
  06:00 UTC with `RebootIfNeeded`.

## 5. Management instance (`compute/` root)

`t3.micro` from the newest golden AMI in a private app subnet:

- No public IP, no SSH key pair, and a security group with no inbound rules.
  Egress goes only to the VPC endpoints and S3.
- IMDSv2 required at hop limit 1 and a gp3 root encrypted with the prod CMK.
- The instance profile has `AmazonSSMManagedInstanceCore` only. Access is SSM
  Session Manager over the existing `ssm`, `ssmmessages` and `ec2messages`
  interface endpoints.
- Tagged `Patch Group = prod`.
- A precondition fails with a clear message if no golden AMI exists yet.

This instance is also the intended target for the incident runbooks
(`aws-incident-forensics` quarantine and snapshot, `event-driven-aws-remediation`).
That wiring belongs to the observability expansion, not this layer.

`scripts/test-compute.sh` proves the baseline live:

1. Prod defaults: EBS encryption and CMK, IMDSv2 account default.
2. Instance posture: golden AMI with the pinned role tag, no public IP, no key,
   IMDSv2 at hop 1, encrypted root on the CMK, no inbound, patch group tag.
3. SSM: Default Host Management role set, agent `Online` through the private
   endpoints.
4. Guest: `check-hardening.sh` is fetched from the role repo at the pinned tag,
   not from the copy baked into the image, and run through Run Command. It is
   the same script as the Azure and GCP proofs.
5. Patching: the instance reports a patch state against the prod baseline.

## Deploy, prove, destroy

```bash
make deploy          # ... workload, observability, then build-image and deploy-compute
make build-image     # stage role, bake + test the AMI once (~30-45 min)
make deploy-compute  # management instance
make test-compute
make test            # includes the sandbox dry-run denials
make destroy         # compute + every golden AMI and snapshot first, then the rest
scripts/verify-teardown.sh   # also fails if any golden AMI is still registered
```

Golden AMIs are created by Image Builder, not Terraform, so they never appear in
state. `make destroy-compute` runs `scripts/clean-images.sh`, which deletes the
image records, AMIs and snapshots before the workload destroy removes the recipe
and schedules the EBS key for deletion.

Incremental cost while up: two `t3.small` build instances for one bake, a
`t3.micro` (~$0.01/hr), and a 10 GiB snapshot until destroy. The rest of the
layer (SCPs, declarative policy, defaults, SSM associations, Image Builder
resources) is free.

## Later

- Karpenter `EC2NodeClass` `metadataOptions.httpTokens: required` in
  `gpu-platform`, and ParallelCluster `CustomAmi` from this pipeline in
  `hpc-slurm-cluster`. Neither repo is changed here.
