# Multi-Cloud Landing Zone: Design Reference

Canonical design reference for three **standalone, isolated** landing zones (AWS, Azure, GCP). The purpose is to demonstrate a high-level, best-practice landing zone per provider. **The three zones do not and will not communicate with each other** by design; there is no cross-cloud connectivity. All three repos build to this document. Posture is **deploy, test/demo, destroy** for every component, so nothing is left standing.

Date: 2026-09-26

## 1. Isolation model

Each landing zone is a self-contained demonstration of one provider's canonical pattern (AWS multi-account strategy, Azure CAF, GCP foundations blueprint). There is intentionally no cross-cloud peering, VPN, or shared address space. Because the zones are isolated, they can reuse the same private address plan, which makes the parity between them obvious.

(A cross-cloud VPN mesh is parked as a separate optional interview-prep lab, not part of these landing zones.)

## 2. Environments and resource hierarchy

Every landing zone provides the same four workload environments plus a platform tier, so the three read identically:

| Tier | AWS | Azure | GCP |
|---|---|---|---|
| Platform | Security OU + Infrastructure OU (network, shared-services, log-archive, audit accounts) | Platform MG: management, connectivity, identity subscriptions | `core` folder: network + logging projects |
| Dev | Workloads OU -> dev account | Workloads MG -> dev subscription | `workloads` folder -> dev project |
| Test | Workloads OU -> test account | Workloads MG -> test subscription | `workloads` folder -> test project |
| Prod | Workloads OU -> prod account | Workloads MG -> prod subscription | `workloads` folder -> prod project |
| Sandbox | Sandbox OU -> sandbox account | Sandbox MG -> sandbox subscription | `sandbox` folder -> sandbox project |

Prod is governed more strictly than dev/test through the same inheritance (SCP / Azure Policy / org policy at the tier), which is the whole point: identical resources, different governance, without policy code in the workload.

## 3. Network topology (same shape in all three clouds)

Hub-and-spoke with centralized egress inspection, per zone. Each zone's hub owns connectivity for that zone only.

- **AWS:** `network` account owns a Transit Gateway. Workload VPCs (dev/test/prod/sandbox) attach to it. A dedicated egress/inspection VPC runs NAT + AWS Network Firewall. Three-layer traffic: ingress, egress, and east-west inspected separately. TGW and subnets shared via RAM. Admin access via SSM Session Manager, no public SSH, no bastion host.
- **Azure:** Hub VNet with Azure Firewall (activated for the demo), Bastion (activated), and a UDR forcing `0.0.0.0/0` from every spoke through the firewall. Spokes peered to hub in both directions.
- **GCP:** Shared VPC per environment (separate host projects), Cloud NAT for egress (zero external IPs), hierarchical firewall policies at org/folder, VPC Service Controls perimeter around data services. IAP-only SSH.

## 4. Address plan (IPAM)

Because the zones are isolated, each cloud uses the **same** plan out of `10.0.0.0/8`. Identical addressing makes the parity explicit and simplifies review.

| Tier | CIDR |
|---|---|
| Platform / hub | `10.0.0.0/16` |
| Dev | `10.1.0.0/16` |
| Test | `10.2.0.0/16` |
| Prod | `10.3.0.0/16` |
| Sandbox | `10.4.0.0/16` |
| Reserved for growth | `10.5.0.0/16` onward |

### Hub subnet layout (`10.0.0.0/16`, Azure example)
| Subnet | CIDR | Purpose |
|---|---|---|
| AzureFirewallSubnet | `10.0.0.0/26` | Azure Firewall (min /26) |
| GatewaySubnet | `10.0.1.0/27` | Reserved for future on-prem VPN/ER gateway |
| AzureBastionSubnet | `10.0.2.0/26` | Bastion (min /26) |
| snet-management | `10.0.3.0/24` | Jump/management, NSG default-deny inbound |

### Kubernetes ranges (carved from the prod `/16`)
| Cloud | Node subnet | Pod range | Service range |
|---|---|---|---|
| AWS (EKS) | `10.3.0.0/20` | `10.3.64.0/18` | `10.3.32.0/19` |
| Azure (AKS) | `10.3.0.0/20` | `10.3.64.0/18` | `10.3.32.0/19` |
| GCP (GKE) | `10.3.0.0/20` | pods secondary `10.3.64.0/18` | services secondary `10.3.32.0/19` |

**Note:** the existing Azure repo currently uses `10.0.0.0/16` for the hub, which matches this plan; its spokes get renumbered to the `10.1-10.4` tiers.

## 5. Networking additions (previously flagged as missing)

1. **Kubernetes network policy.** Cilium or Calico (native where available) enforcing default-deny pod-to-pod, so segmentation follows traffic into the pod network, mirroring the VPC-edge default-deny.
2. **DNS as a first-class design.** A private resolver in each zone's hub; spokes forward to it. Private zones for the private endpoints (Route 53 Resolver, Azure Private DNS + resolver, Cloud DNS private zones). Scoped within each zone only.
3. **Hybrid connectivity placeholder.** Gateway subnet / TGW VPN attachment / HA VPN stub reserved but not provisioned, representing a future on-prem connection (Interconnect / ExpressRoute / DX as the production upgrade). No cross-cloud use.
4. **DDoS / edge.** Free **Standard/always-on** DDoS is enabled by default in AWS and Azure, so baseline protection exists at no cost. **GCP Cloud Armor** has cheap pay-as-you-go rules and is demoable. **Shield Advanced / Azure DDoS Network Protection are documented-as-designed only** (each ~$3,000/mo, cannot be deployed and destroyed cheaply). WAF at the ingress path where it is cheap to demo.

## 6. Private connectivity (no public path)

Private/interface endpoints so the registry, secrets manager, and central logging are reached over private IPs with internet egress denied:
- AWS: VPC interface endpoints for ECR, ECR-dkr, S3 (gateway), Secrets Manager, CloudWatch Logs, SSM.
- Azure: Private Endpoints + Private DNS zones for ACR, Key Vault, storage, Log Analytics.
- GCP: Private Google Access + Private Service Connect for Artifact Registry and Secret Manager.

Default-deny egress through the hub firewall is what enforces the container pull-through cache: nodes cannot reach Docker Hub directly, only the private registry.

## 7. Best-practice additions (all adopted)

From the AWS SRA / Azure CAF / GCP foundations conformance review, all seven adopted:

1. **AWS: Infrastructure OU** (network + shared-services accounts) and a **Test/pre-prod tier distinct from Prod** (see section 2).
2. **AWS: three-layer traffic model** (ingress + egress + east-west inspection) (see section 3).
3. **Azure: dedicated platform subscriptions** (management, connectivity, identity) (see section 2).
4. **All: explicit human-identity federation / SSO onboarding** (IAM Identity Center, Entra ID, Cloud Identity) as its own design step, distinct from workload identity.
5. **All: management/root account hardening** (root/global-admin MFA, unused, alarmed) documented alongside break-glass.
6. **Docs: position bespoke Terraform vs the native accelerators** (LZA, Azure Verified Modules, GCP foundations blueprint) as a deliberate choice, per repo.
7. **GCP: per-environment Shared VPC** (separate host projects for dev/test/prod) (see section 3).

## 8. Cost and teardown

The guardrails-and-topology layer is nearly free; the risk is a forgotten hourly resource, not the demo itself.

### Standing cost (guardrails + topology layer)
| Component | Standing cost |
|---|---|
| Subnets, SG/NSG/firewall rules, policies, VPC-SC, empty backup vault | Free |
| Backup CMK | ~$1/mo AWS, ~$0.06/mo GCP, negligible Azure |
| **Leave standing after destroy** | **~$1 to $3/mo (KMS only)** |

### Bills hourly, MUST be destroyed after demo
| Resource | Approx rate | Left-standing/mo |
|---|---|---|
| Private/interface endpoints | ~$0.01/hr each | ~$7/mo each |
| NAT gateway | ~$0.045/hr | ~$32/mo |
| Azure Firewall | ~$0.90-1.25/hr | ~$650+/mo |
| AWS Network Firewall | ~$0.40/hr + NAT | ~$290+/mo |
| Managed DB (Multi-AZ/HA doubles it) | ~$0.03-0.50/hr | varies |
| k8s managed control plane | ~$0.10/hr | ~$70/mo |

### Demo-window cost (deploy, ~2 hrs, destroy) per zone
| Layer | ~2-hr cost |
|---|---|
| Guardrails + topology | ~$0.20 |
| Inspection appliances + NAT | ~$3-5 |
| DB + backup + failover | ~$1-2 |
| **Per-zone session** | **~$4-7** (under $2 if appliances are only up for their own demo) |

Never deployed (documented only): Shield Advanced, Azure DDoS Network Protection.

### Teardown check (bake into each repo)
Each repo's teardown runs `terraform destroy` then verifies no hourly resource survives:
- **AWS:** detach TGW attachments before delete; confirm no NAT gateways, Network Firewall, VPC endpoints, or RDS instances remain; check orphaned EIPs and snapshots.
- **Azure:** Firewall takes 10-30 min to delete; confirm Private Endpoints, Firewall, and SQL DBs are gone; delete the resource group last.
- **GCP:** delete Cloud NAT; respect sink/project deletion order; confirm no Cloud SQL instances or forwarding rules remain.

Azure SQL failover groups require a tier above the cheapest Basic DTU. Multi-AZ/HA is toggled on only for the failover demo.

## 9. Pipeline

The shared toolkit in `platform-guardrails` is the standard; the gap is coverage, not capability.

### Standardize all three repos onto the reusable workflows
| Repo | Today | Target |
|---|---|---|
| AWS | bespoke `validate.yml` (fmt/validate only) | call `tf-ci.yml` + `tf-plan.yml` + `finops-gate.yml` |
| Azure | own report-only `security-gate.yml` | call the reusable workflows; retire the duplicate |
| GCP | `tf-ci.yml@v1` with `skip_policy: true` | **turn policy on**; add plan/apply/destroy |

### Existing gates (keep)
Full-history gitleaks (hard gate), fmt + validate, lock-file-committed assertion, tflint, Checkov, Trivy config, conftest OPA (tags/network/cost/finops), destroy-guard (blocks stateful delete/replace without `destroy-approved`), Infracost threshold gate ($50/mo default, `cost-approved` override).

### Additions needed
1. **Multi-cloud OIDC.** `tf-plan.yml` is AWS-only today; add Azure and GCP OIDC auth paths (or sibling workflows) so plan + destroy-guard + cost diff work on all three.
2. **Gated apply.** New `tf-apply.yml` bound to a GitHub environment with a required reviewer = the just-in-time-to-prod control expressed in CI.
3. **Destroy + TTL auto-destroy.** New `tf-destroy.yml` plus a scheduled job that destroys (or alarms on) anything still standing after N hours. Pipeline enforcement of the section 8 teardown checklist.
4. **GCP policy coverage.** Add `google_compute_firewall` / `google_*` region rules to `network.rego` and `cost.rego` so the policy gate is real on all three clouds.
5. **Supply-chain gates.** cosign signing + SBOM (Syft) + provenance attestation on the container path, admission-verify (Kyverno/Binary Authorization) at deploy.

## 10. Master build plan (per isolated landing zone)

| Phase | Scope | Clouds | Cost posture |
|---|---|---|---|
| **0. Design lock** | This doc | all | free |
| **1. Pipeline standardization** | Wire 3 repos to `platform-guardrails`; multi-cloud OIDC; gated apply; destroy + TTL auto-destroy; GCP OPA rules | all | free |
| **2. AWS to parity** | Security OU + **Infrastructure OU** + Sandbox OU + Workloads OU (dev/test/prod accounts); TGW; egress/inspection VPC + Network Firewall (3-layer traffic); VPC endpoints; SSM; flow logs; log-archive + audit accounts; org CloudTrail + Config + Security Hub CIS; KMS CMK; tag policies; budgets; **IAM Identity Center federation**; **root hardening** | AWS | cents standing, timed for firewall/NAT |
| **3. Azure gap-close** | renumber spokes to `10.1-10.4`; **platform subs (management/connectivity/identity)**; Workloads MG (dev/test/prod subs); activate Firewall + Bastion + UDR; private endpoints + DNS; Log Analytics + Defender CIS; Key Vault CMK; flip policies Audit->Deny + CIS initiative; budgets; **Entra federation + PIM**; **global-admin hardening** | Azure | cents standing, timed for firewall |
| **4. GCP hardening** | **per-environment Shared VPC** (dev/test/prod host projects); Cloud NAT; hierarchical firewall; VPC-SC; un-skip OPA policy; **Cloud Identity federation**; **org-admin hardening** | GCP | ~$0.50/mo standing |
| **5. Data tier** | data subnets + segmentation matrix; isolated backup vault + Vault Lock/immutability; small managed DB per zone (timed); failover demo | all | cents standing, ~$1-2 timed |
| **6. Workloads on the paved road** | k8s live demo on **ONE cloud** (workload identity, ESO + secrets-lifecycle, CMK etcd, Kyverno/Binary Auth, private API); other two reference-wired; supply chain: private registry + pull-through cache + cosign/SBOM/attest | one live, others ref | ~$70/mo/cluster while up, timed only |
| **7. Compliance docs** | CIS control mapping per repo; access-model persona matrix; accelerator-vs-bespoke note; this doc | all | free |

Reuse map: personas/backups/failover/supply-chain/k8s lean on existing repos (`*-secrets-lifecycle`, `*-backup-system`, `multi-region-failover-manager`, `azure-multi-region-failover`, `gcp-supply-chain-security`, `azure-aks-runtime-security`, `eks-terraform`, `gcp-gke-config-sync`, `gcp-workload-identity-federation`) pointed at landing-zone outputs.

## 11. Best-practice conformance (AWS SRA / Azure CAF / GCP Security Foundations)

Graded against: AWS Control Tower multi-account strategy + Security Reference Architecture + Landing Zone Accelerator; Azure Cloud Adoption Framework design areas (A-I); GCP landing zone design + enterprise foundations blueprint.

### Conforms
- Multi-account/sub/project isolation with OU/MG/folder hierarchy and dev/test/prod + platform tiers.
- Preventive guardrails as policy-as-code, inherited through the hierarchy.
- Centralized logging to a dedicated account/project + detective monitoring (Security Hub / Defender / SCC).
- Least-privilege identity via federated SSO, break-glass, root hardening, no static keys.
- IaC everywhere, automation/consistency, governance applied early.
- Cost governance and CMK encryption.
- All seven framework adds adopted (section 7).

### De-scoped (deliberate)
| Change | Reason |
|---|---|
| **Cross-cloud connectivity removed entirely** | Purpose is a standalone LZ per provider; zones do not communicate. Cross-cloud VPN parked as a separate optional lab |
| **Live k8s reduced to one cloud** | A cluster is a workload, not the LZ; one live demo proves the paved road, others reference-wired |
| **Active-active multi-region DB out** | Active-passive only; cost/consistency overhead with no portfolio benefit |
| **Shield Advanced / Azure DDoS Network Protection: documented only** | ~$3,000/mo each, cannot be deployed/destroyed cheaply; free Standard tier covers baseline |
