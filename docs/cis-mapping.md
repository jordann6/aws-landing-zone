# CIS AWS Foundations Benchmark mapping

How this landing zone implements the CIS AWS Foundations Benchmark (v1.4.0), by
control, pointing at the exact Terraform resource or policy that satisfies it.
Rows marked "N/A (demo)" are honestly out of scope for a deploy/demo/destroy
portfolio account and are called out rather than faked. Security Hub's CIS
standard (`aws_securityhub_standards_subscription.cis`) provides the live scored
view; this table is the design-time intent behind that score.

## 1. Identity and Access Management

| CIS | Control | Implemented by |
|---|---|---|
| 1.1 | Maintain current contact details | N/A (demo): account metadata, not IaC |
| 1.4 | No root access keys | `root-hardening.tf` alarms on any root use; key removal is a documented one-time action |
| 1.5 | MFA on root | Manual one-time action, documented in `access-model.md`; the root-activity alarm proves it stays unused |
| 1.6 | Hardware MFA on root | Same as 1.5 |
| 1.7 | Avoid root for daily tasks | `deny-root-user` SCP (`policies/deny-root-user.json`) blocks all root actions in members |
| 1.8 | Password policy min length 14 | `aws_iam_account_password_policy.strict` |
| 1.9 | Password reuse prevention | `aws_iam_account_password_policy.strict` (24) |
| 1.10 | MFA for all IAM users | Partial: humans have no IAM users and federate through Identity Center (`identity.tf`). The one automation user, `terraform-user`, has no console login and no MFA |
| 1.12 | No unused credentials | Not met: `terraform-user` has one active access key created 2025-02-13. Humans use short-lived Identity Center sessions (`session_duration`). Retiring the key is open |
| 1.16 | No full "*:*" policies attached | Delegated personas are capped by permissions boundaries (`aws_ssoadmin_permissions_boundary_attachment`) |
| 1.20 | IAM Access Analyzer enabled | Service access enabled in `organization.tf`; analyzer rollout tracked as a follow-up |

## 2. Storage

| CIS | Control | Implemented by |
|---|---|---|
| 2.1.1 | S3 encryption at rest | `aws_s3_bucket_server_side_encryption_configuration` on the trail (KMS) and config (SSE-S3) buckets |
| 2.1.2 | S3 deny non-TLS | `DenyInsecureTransport` statement in the trail and config bucket policies |
| 2.1.5 | S3 Block Public Access | `aws_s3_bucket_public_access_block` on both buckets; `deny-public-s3` SCP at the org root (no public bucket ACLs anywhere; only the break-glass role may change an account-level public access block) |

## 3. Logging

| CIS | Control | Implemented by |
|---|---|---|
| 3.1 | CloudTrail enabled all regions | `aws_cloudtrail.org` (`is_multi_region_trail`, `is_organization_trail`) |
| 3.2 | CloudTrail log file validation | `aws_cloudtrail.org` (`enable_log_file_validation`); tampering denied org-wide by the `DenyCloudTrailTampering` statement in the root `deny-disable-detective` SCP, plus Object Lock on the bucket |
| 3.3 | CloudTrail bucket not public | `aws_s3_bucket_public_access_block.trail` + `deny-public-s3` SCP (root) |
| 3.4 | CloudTrail to CloudWatch Logs | N/A (demo): deferred; detection is via GuardDuty + Security Hub |
| 3.5 | AWS Config enabled | Every account records. The security account records all supported types (`config.tf`). The other member accounts get a recorder from a service-managed StackSet that auto-deploys to new accounts in the target OUs, and the management account has its own (`config-org.tf`). Those recorders are limited to security groups, instances, load balancers, web ACLs and buckets to keep the standing cost near zero; a production rollout records all supported types. An organization aggregator in the security account, the Config delegated administrator, reports all nine accounts |
| 3.6 | CloudTrail bucket access logging | N/A (demo): access logging a log bucket is recursive |
| 3.7 | CloudTrail logs encrypted with KMS | `aws_cloudtrail.org` (`kms_key_id` = `aws_kms_key.logging`) |
| 3.8 | KMS key rotation | `aws_kms_key.logging` (`enable_key_rotation = true`) |
| 3.9 | VPC flow logging | `aws_flow_log.hub` in the network root |

## 4. Monitoring

| CIS | Control | Implemented by |
|---|---|---|
| 4.x | Metric filters and alarms (root use, policy changes, etc.) | Root use: `aws_cloudwatch_event_rule.root_activity` to SNS. The remaining metric-filter alarms are the CloudWatch Logs integration deferred in 3.4; GuardDuty covers the threat-detection intent |
| 4.15 | Org-wide security findings | GuardDuty + Security Hub delegated to the security account (`detective.tf`) with org auto-enable |

## 5. Networking

| CIS | Control | Implemented by |
|---|---|---|
| 5.1 | No ingress to admin ports from 0.0.0.0/0 | No public admin path exists; access is SSM Session Manager over private endpoints (`endpoints.tf`), no bastion, no public SSH |
| 5.3 | Default security group restricts all traffic | `aws_default_security_group.hub` (no rules) |
| 5.4 | Routing tables least access | Inspection routing (`routing.tf`) forces all egress and return traffic through the firewall |
| Beyond CIS | Internet-facing edge inspected | The only public listener is the ingress load balancer (`ingress.tf`), behind a WAF web ACL with the IP reputation list, a per-IP rate limit and the Common and known-bad-input rule groups. Every request and its verdict is logged to `aws-waf-logs-*` in log-archive (`terraform/waf-logs.tf`). Firewall Manager is administered from the security account with its org-wide WAF policy written and off (`fms.tf`) |

## Data tier and workload (Phase 5/6)

| Control | Implemented by |
|---|---|
| RDS encryption at rest with CMK | `aws_db_instance.prod` (`storage_encrypted`, `kms_key_id`) |
| RDS not publicly accessible | `aws_db_instance.prod` (`publicly_accessible = false`), private subnets, no IGW/NAT |
| RDS credential not in code | `manage_master_user_password` (RDS-managed secret in Secrets Manager) |
| Database reachable only from the app tier | `aws_security_group.db` ingress from the app SG only, plus the data NACL |
| Immutable backups | `aws_backup_vault_lock_configuration.prod` (WORM); cross-region copy is opt-in after region approval |
| EKS secrets encrypted in etcd | `aws_eks_cluster.prod` `encryption_config` with a CMK |
| EKS private control plane | `aws_eks_cluster.prod` (`endpoint_public_access = false`) |
| Pod-scoped IAM, no static keys | IRSA via `aws_iam_openid_connect_provider.eks` (`irsa.tf`) |
| EKS control-plane audit logging | `aws_eks_cluster.prod` `enabled_cluster_log_types` |
| Image scanning | ECR scan-on-push + Inspector enhanced scanning (`ecr.tf`) |
| Only private registry pulls | No internet path + hub firewall allowlist; pull-through cache mirrors into ECR |
| Hardened standalone image | Image Builder: Amazon STIG + shared `cis_baseline` role, tested after reboot (`imagebuilder.tf`) |
| IMDSv2 only | SCP `require-imdsv2`, declarative policy `instance_metadata_defaults` (owns the account default), node launch template and instances at hop limit 1 |
| EBS encrypted by default | SCP `require-encrypted-ebs`, Workloads declarative policy, default CMK (`compute-defaults.tf`) |
| Only approved images | Declarative policy `allowed_images_settings` (Amazon AL2023 + prod golden AMIs; Workloads adds the EKS-optimized AL2023 node images) |
| OS patching | SSM patch baseline, patch group and scan/install associations (`ssm-patching.tf`) |

## Preventive controls beyond CIS scoring

The SCPs enforce several controls preventively that CIS only checks detectively:
region lockdown (`region-lockdown`), deny leaving the org (`deny-leave-org`),
deny disabling the detective services or tampering with any trail
(`deny-disable-detective`), deny public S3 (`deny-public-s3`), and require S3
encryption (`require-s3-encryption`). Accounts in the Suspended OU are frozen
by `deny-all`. A preventive deny is stronger than a
detective finding, so where both are possible this zone denies.

## Where each SCP is attached, and why

| SCP | Attached at | Why there |
|---|---|---|
| `deny-root-user`, `deny-leave-org` | Root | Applies to every member account without exception |
| `deny-disable-detective` (Config, GuardDuty, Security Hub, Access Analyzer, CloudTrail tampering) | Root | The detective services and the org trail are org-wide, so the guard is too. The CloudTrail and Config statements exempt only `OrganizationAccountAccessRole`, the operator break-glass role, so a member-owned trail (the secrets scanner's `secops-trail`) or a stale lab recorder can still be torn down. GuardDuty, Security Hub and Access Analyzer have no exemption. CI roles and Identity Center personas are not exempt |
| `deny-public-s3` | Root | A public bucket leaks the same data from dev or sandbox as from prod. The account-level public access block statement exempts the break-glass role so the block can be set once per account |
| `region-lockdown` | Security, Infrastructure, Sandbox, Workloads, Deployments | Every OU with member accounts. Security was missing it until 2026-11-20; all of its services run in us-east-1 (checked across all 17 regions) |
| `require-s3-encryption` | Infrastructure, Workloads | The OUs that hold the platform's data. Not yet on Security or Sandbox: S3 has encrypted every new object by default since 2023, so the SCP's job is forcing an explicit KMS header, and widening it means first checking every writer in those accounts sends one (the backup-verify heartbeat needed exactly that fix). Open item |
| `require-imdsv2`, `require-encrypted-ebs` | Sandbox, Workloads | The OUs that run EC2 |
| `deny-all` | Suspended | Account lifecycle. Moving an account here freezes every principal in it before closure; CloseAccount runs from the management account, which no SCP binds |

The root is at the AWS limit of 5 SCPs per target (`FullAWSAccess` plus four),
which is why the CloudTrail guard is a statement inside `deny-disable-detective`
instead of a policy of its own. The management account is never bound by an SCP,
so the org trail it owns is protected by being in that account, and its changes
go through the gated governance pipeline.
