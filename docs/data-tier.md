# Data tier and paved-road workload

The `workload/` root builds the prod paved road: a private VPC, a segmented data
tier with a Multi-AZ database, immutable backups, and an EKS cluster that pulls
only from a private registry and encrypts its secrets with a customer-managed key.

## Who can talk to whom

Segmentation is enforced at three levels: security groups (stateful), a NACL on
the data subnets (stateless, defense in depth), and account/VPC isolation between
environments.

| Source | Destination | Port | Allowed | Enforced by |
|---|---|---|---|---|
| app tier | database | 5432 | yes | db SG ingress from app SG only; data NACL |
| app tier | internet | 443 | yes, inspected | app SG egress 443, via TGW to the hub firewall |
| database | anything outbound | any | no (responses only) | db SG egress limited to the VPC |
| node/other tiers | database | 5432 | no | not in db SG; denied by the data NACL |
| dev or test data tier | prod data tier | any | no | separate accounts and VPCs, no peering, no spoke-to-spoke routing on the TGW |
| anything | database | public | no | RDS `publicly_accessible = false`, private subnets, no IGW/NAT |

The database is reachable only from the application tier, on one port, from
inside one VPC. Cross-environment data isolation is structural: dev, test, and
prod are different accounts with different VPCs and no path between them.

## Availability: RTO and RPO

| Property | Value | How |
|---|---|---|
| Model | Active-passive | RDS Multi-AZ: a synchronous standby in the second AZ |
| RPO | ~0 (no data loss) | Synchronous replication to the standby |
| RTO | ~1 to 2 minutes | AWS detects failure and promotes the standby automatically (DNS flips to the new primary) |
| Backup RPO | 1 day (schedule) plus 5-minute PITR window | Daily AWS Backup plus RDS continuous backup |
| DR region | Cross-region copy | Backup plan copies each recovery point to a vault in the DR region |

`make test` forces the failover (`reboot-db-instance --force-failover`) and
confirms the primary moves to the other AZ, then checks the backup vault is
locked and the EKS endpoint is private.

## Backups: immutability

The backup vault uses AWS Backup Vault Lock. Within the retention window a
recovery point cannot be deleted or shortened by anyone, including the account
root, which is what makes the backup a defense against ransomware and not just
hardware failure. `changeable_for_days` keeps the lock adjustable briefly so the
demo can be torn down; production sets it to 0 for immediate compliance-mode WORM.

Demo scope: the vault lives in the prod account. Production isolates it in a
separate backup account via AWS Backup cross-account copy and an org backup
policy, so a compromise of prod cannot reach the backups. The cross-region copy
is built; the cross-account isolation is the documented upgrade.

## Supply chain and the cluster

- **Private registry only.** The prod VPC has no internet path, and the hub
  firewall's allowlist does not include Docker Hub, so a node cannot reach a
  public registry. Images come from ECR; public images come through the ECR
  pull-through cache, which mirrors them into ECR where Inspector scans them.
- **Immutable tags + scanning.** ECR tags are immutable, scan-on-push is on, and
  Inspector enhanced scanning runs continuously across ECR and EC2.
- **Private control plane.** The EKS API endpoint is private; there is no public
  control plane. Reaching it means being on the network (over the TGW).
- **Secrets.** Kubernetes secrets in etcd are envelope-encrypted with a CMK. Pods
  get scoped IAM through IRSA: the External Secrets Operator example can read
  exactly one Secrets Manager secret (the RDS master credential) and nothing else.
- **Golden image.** An EC2 Image Builder pipeline produces a patched, hardened
  Amazon Linux 2023 AMI for the node group to pin to.

The remaining supply-chain controls (cosign signing, SBOM generation, provenance
attestation, and admission verification via Kyverno) run in the CI and cluster
layers and reuse the pattern from `gcp-supply-chain-security`; they are the
runtime half of this design rather than Terraform resources.
