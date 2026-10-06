# Compute baseline

The same three-part baseline runs in all three landing zones: preventive
guardrails that deny a non-compliant instance, one shared hardening role baked
into a golden image, and a cloud-native patch service. Every zone also runs one
hardened management instance built from its golden image, with no public IP,
reachable only through the cloud's private access path.

> One hardening role, three image pipelines, three enforcement points: Azure
> Policy approved-image deny, GCP `compute.trustedImageProjects`, AWS Allowed AMIs.

**Status:** the guardrails are live on the Sandbox OU and, since the reviewed
promotion on 2026-10-06, the Workloads OU (Dev, Test, Prod). `scripts/test-guardrails.sh`
proves them with dry runs in sandbox (sections 5 to 9) and prod (10 to 15), 20/20
passing. The rest of the layer
was deployed, proven and destroyed in one session on 2026-10-06, with the full
EKS and RDS workload up alongside it:

| Proof | Result |
|---|---|
| `scripts/test-data-tier.sh` | 5/5 |
| Golden AMI test phase (fresh instance, after reboot) | `HARDENING_OK`, 26 PASS, fail2ban SKIP |
| `scripts/test-compute.sh` | 17/17 |
| `scripts/verify-teardown.sh` | clean, KMS-only footprint |

Session cost was about $3 to $3.50 (about 2.5 hours at roughly $1.15/hr).

### What the first live bake changed

None of these were visible to the static gates; each surfaced on the first apply
or bake and is fixed in code.

- `stig-build-linux-medium` is deprecated and cannot go into new recipes. The
  recipe uses the unified `stig-build-linux` component with `Level = Medium`.
- Image Builder lifecycle `DEPRECATE` accepts only an `AGE` filter. Both rules use
  `AGE` with `retain_at_least`.
- The build instance fetches components through the Image Builder API, so the
  prod VPC has an `imagebuilder` interface endpoint.
- The org `require-s3-encryption` SCP denies a `PutObject` with no SSE header, so
  `stage-role.sh` sends `--sse AES256`.
- STIG and the role collide twice, and STIG won both at boot. STIG's
  `/etc/sysctl.d/99-sysctl.conf` sorts after the role's `99-hardening.conf`
  (`kptr_restrict` 1 instead of 2), and STIG re-adds audit rules the role already
  loads, so the kernel rejects the duplicate (`Rule exists`) and `augenrules`
  stops before the trailing `-e 2`. STIG's own reload discards that error. A
  `reconcile-stig` build step drops the role's sysctl keys from STIG's files and
  removes each STIG audit rule the kernel rejects until the merged rules load
  cleanly; a rejected rule that is not STIG's fails the build. A
  `boot-diagnostics` test step logs the boot-time audit and sysctl state to the
  `/aws/imagebuilder/lz-hardened-al2023` log group, which is how this was found
  after Image Builder terminated the failed test instance.
- A bake that fails its test phase leaves an untagged AMI. `clean-images.sh` and
  `verify-teardown.sh` match the pipeline's AMI name as well as the tag.
- Component and recipe versions are immutable: major.minor follow the role and the
  patch is the role patch times 100 plus a wrapper revision (`2.0.103`).

## 1. Preventive guardrails (accounts root, Sandbox and Workloads OUs)

| Control | Implementation | Proof (`scripts/test-guardrails.sh`, free `--dry-run`) |
|---|---|---|
| IMDSv2 required at launch, no downgrade | SCP `require-imdsv2` | `run-instances --metadata-options HttpTokens=optional` is denied. Live, the declarative policy's `httpTokensEnforced` rejects it first (`UnsupportedOperation`), so the SCP is the second layer |
| No unencrypted EBS; default encryption cannot be disabled | SCP `require-encrypted-ebs` | `create-volume --no-encrypted` is denied by an explicit SCP deny |
| Allowed AMIs: Amazon AL2023 plus golden AMIs owned by prod; Workloads also allows the EKS-optimized AL2023 node images | Declarative policies `sandbox-ec2-baseline` and `workloads-ec2-baseline` (`allowed_images_settings`), one template | Canonical Ubuntu AMI is hidden: it is `available` from the management account but `InvalidAMIID.NotFound` in sandbox and prod. Compliant AL2023 launch reaches `DryRunOperation`. The EKS node AMI reports `ImageAllowed=True` in prod |
| IMDS defaults enforced (IMDSv2 required, hop limit 1), serial console off, AMI and snapshot public sharing blocked | Same declarative policies | `get-allowed-images-settings`, `get-instance-metadata-defaults` (tokens `required`, hop limit `1`) in sandbox and prod |

Both SCPs exempt only the Identity Center break-glass role in the accounts under
the two OUs (sandbox, dev, test, prod). The exemption is inert until the
governance root assigns the break-glass persona in that account; today only
`breakglass:sandbox` exists, so no principal in dev, test or prod is exempt.

### Workloads OU promotion (2026-10-06)

The sandbox criteria would have broken the prod node group. The EKS-optimized
AL2023 AMI is Amazon-owned (provider `amazon`), but its name,
`amazon-eks-node-al2023-x86_64-standard-<version>-<date>`, does not match
`al2023-ami-*-x86_64`, and in sandbox `describe-images` hides it. The Workloads
policy adds that name pattern, unpinned so a cluster upgrade keeps working.

The rollout ran in two reviewed applies. The first attached both SCPs and
`workloads-ec2-baseline` with Allowed AMIs in `audit_mode`; prod then reported
`ImageAllowed=True` for the EKS 1.35 node AMI and the AL2023 parent, and `False`
for a Canonical Ubuntu control. The second switched Allowed AMIs to `enabled`.
The sandbox policy moved to `ec2_baseline["sandbox"]` through `moved` blocks
with identical content, so its live attachment was never recreated.

Every EC2 path in the workload and compute roots was checked against the new
denials. EKS nodes and the Image Builder build and test instances launch through
service-linked roles, which SCPs do not apply to; their launch template and
infrastructure configuration already set IMDSv2 at hop 1 and encrypted gp3, and
their images match the criteria. The management instance is compliant. No EBS
CSI driver is installed, so nothing creates unencrypted volumes. RDS is not
affected. The golden AMI criterion is the same one sandbox enforces; the next
bake confirms it in prod.

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

- `aws_ebs_default_kms_key` set to a
  dedicated `alias/prod-ebs` CMK with rotation. The key policy mirrors the
  AWS-managed `aws/ebs` key (any principal in the account, only through EC2). This
  covers the Auto Scaling and Image Builder service-linked roles without naming
  them, so it does not fail in an account where they do not exist yet.
- IMDSv2 required at hop limit 1 as the account default. The Workloads OU
  declarative policy owns this attribute (`ManagedBy = declarative-policy`), so
  `aws_ec2_instance_metadata_defaults` is off unless
  `manage_instance_metadata_defaults = true`.
- EKS node group launch template (`eks.tf`): IMDSv2 at hop limit 1 and a
  KMS-encrypted gp3 root. Nodes stay on the EKS-optimized AL2023 image, which EKS
  versions and patches with the control plane. The golden AMI is for standalone
  instances only.

## 3. Golden AMI (workload root, `imagebuilder.tf`)

```
AL2023 (SSM public parameter)
  -> Amazon STIG component (stig-build-linux, x.x.x, Level=Medium)
  -> cis-baseline component: dnf upgrade, cis_baseline role from S3, offline
  -> test phase on a NEW instance booted from the AMI: check-hardening.sh
  -> distribution: KMS-encrypted AMI, tagged, optionally shared to the org
  -> Inspector scan; lifecycle policy deprecates after 7 days and deletes after 30, keeping the newest
```

- The role is the same `cis_baseline` role from `azure-vm-hardening`, at the
  same pinned tag (`v2.0.1`) the Azure and GCP pipelines bake. It runs offline:
  `make stage-role` packages the tag plus `community.general` 9.x, then uploads
  it to a private SSE-S3 bucket that the build role reads through the S3 gateway
  endpoint. The build has no internet path, and AL2023 package repos are also
  S3-backed.
- STIG runs first, then the role, then `reconcile-stig`, so the role's settings
  win any overlap, at boot as well as at build time. These are the settings the
  shared test checks on all three clouds.
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
