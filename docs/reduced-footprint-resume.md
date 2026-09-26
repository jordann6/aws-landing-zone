# Reduced-footprint deploy and full-deploy resume

This org was deployed at its 10-account limit, so the governance root ran with a
reduced footprint. The canonical design is unchanged in code (all toggles default
`true`); the reduction lives only in the gitignored `terraform/terraform.tfvars`.

## What is deployed now (reduced footprint)

- Organization (imported: `o-rpfh5h9ite`), OUs, all SCPs, tag policy fixed but
  gated off, budget.
- Accounts: `security`, `log-archive`, `sandbox` only. `dev/test/prod/network/
  shared-services` gated off via `full_account_set = false`.
- WORM CloudTrail + KMS CMK, AWS Config + CIS conformance pack, GuardDuty
  (org-wide, security-account admin), Identity Center personas + the assignments
  whose target accounts exist.
- Gated off for this org: `enable_securityhub`, `enable_cost_anomaly_monitor`,
  `enable_tag_policy` (see reasons below).

## Why each toggle is off in terraform.tfvars

- `full_account_set = false` — org is at its account-count limit (10). A quota
  increase to 20 is requested (Service Quotas `L-E619E033`).
- `enable_securityhub = false` — Security Hub is already enabled in the security
  account (default standards auto-subscribed). Needs an import, not a create.
- `enable_cost_anomaly_monitor = false` — a SERVICE-dimension monitor already
  exists in the account (`Default-Services-Monitor`); AWS allows only one.
- `enable_tag_policy = false` — was gated during triage; the document is now
  fixed (dropped the non-enforceable `rds:db`) and validates, so this can go true.

## Full-deploy resume (once the account quota is raised to 20)

1. Edit `terraform/terraform.tfvars`:
   - `full_account_set = true`
   - `enable_tag_policy = true`   (document is fixed and API-validated)
   - `enable_securityhub = true`  (then import, step 2)
   - leave `enable_cost_anomaly_monitor = false` (existing SERVICE monitor blocks a
     second one; delete `Default-Services-Monitor` first if you want ours)

2. Import the already-enabled Security Hub account BEFORE applying, or the apply
   fails with "Account is already subscribed":

   ```
   terraform -chdir=terraform import 'aws_securityhub_account.security[0]' 991166714466
   ```

   The `cis` subscription (v1.4.0) and the org admin / org configuration are NOT
   present and will be created. The auto-enabled CIS v1.2.0 + FSBP standards will
   remain unmanaged; optionally disable them or add `enable_default_standards =
   false` to `aws_securityhub_account` for a clean CIS-1.4.0-only posture.

3. Apply governance (creates the 5 remaining accounts + dev/test/prod SSO
   assignments + tag policy + Security Hub CIS 1.4.0):

   ```
   terraform -chdir=terraform apply
   ```

4. Deploy the network and workload roots (hourly cost starts here — Network
   Firewall, NAT, EKS, RDS Multi-AZ):

   ```
   make deploy   # governance is idempotent; it then feeds outputs into network + workload
   ```

5. Full test + teardown:

   ```
   make test      # includes data-tier once workload is up
   make destroy
   ```
