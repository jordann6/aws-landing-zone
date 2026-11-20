# ADR-0006: Hybrid connectivity, Direct Connect primary with VPN failover

- **Status:** accepted 2026-11-20 (design only; nothing in this ADR is deployed)
- **Date:** 2026-11-20

## Context

The enterprise reference this zone was compared against shows an on-premises
data center joined to the AWS network. This zone has no on-premises side, and
`docs/multicloud-networking-design.md` already reserves the slot ("TGW VPN
attachment ... reserved but not provisioned"). Cross-cloud links to Azure or
GCP stay out of scope by design; that line in the design doc does not change.

What exists today, and what any hybrid link has to fit into:

- One Transit Gateway in the network account (`network/tgw.tf`), shared to the
  org over RAM, Amazon-side ASN 64512 (the default).
- Two TGW route tables (`network/tgw-routing.tf`). `lz-spoke-egress` gives every
  spoke a single `0.0.0.0/0` to the inspection VPC and no route to any other
  spoke. `lz-inspection-return` carries the spoke routes back.
- Network Firewall in the inspection VPC, today an egress domain allowlist.
- The address plan, `10.0.0.0/16` (hub) through `10.4.0.0/16` (sandbox), with
  `10.5.0.0/16` onward reserved. All of it sits inside `10.0.0.0/12`.

The binding constraint is money, not design. Every piece of real hybrid
connectivity bills by the hour whether or not traffic flows, and a VPN with no
customer gateway on the other end proves nothing: both tunnels sit DOWN.

## Decision

Document the production design here, and do not build either link for the demo.

**Production design.** One Direct Connect connection carries a transit virtual
interface to a Direct Connect gateway, which is associated with the existing
Transit Gateway. A Site-to-Site VPN attaches to the same Transit Gateway as the
failover path. Both run BGP, so failover is a routing decision, not a runbook.

```
on-prem router (ASN 65010)
  |  BGP over DX (primary)            BGP over IPsec, 2 tunnels (failover)
  v                                   v
Direct Connect gateway (ASN 64513)    Site-to-Site VPN attachment
  |  allowed prefix 10.0.0.0/12       |
  +--------------> Transit Gateway (ASN 64512) <---+
                         |
                  lz-onprem route table (new)
                         |  10.1-10.4/16 -> inspection VPC attachment
                         v
                  Network Firewall -> spoke
```

**Path selection, both directions.**

- *AWS to on-prem.* When the same on-prem prefix arrives over both paths, the
  Transit Gateway prefers routes propagated from a Direct Connect gateway over
  routes propagated from a VPN attachment, after longest prefix match. No
  tuning is needed on the AWS side; DX wins until its routes are withdrawn.
- *On-prem to AWS.* The on-prem router makes this choice, so it is configured
  there. Set a higher BGP local preference on routes learned over DX, and
  prepend the AWS-facing advertisements on the VPN sessions so the AWS side
  also sees VPN as the longer path. Bidirectional Forwarding Detection on the
  DX BGP session brings failover down to seconds instead of the default BGP
  hold timer (90 seconds).

**Inspection of hybrid traffic.** The DX gateway and VPN attachments associate
with a new `lz-onprem` route table, not with `lz-spoke-egress`. Its routes send
each spoke CIDR to the inspection VPC attachment, so traffic from on-prem goes
through Network Firewall exactly like egress does. The on-prem prefixes
propagate into `lz-inspection-return`, so the return path is inspected too. The
firewall needs a stateful rule group for on-prem flows (allowed ports per
spoke) beside today's domain allowlist.

**Address plan.** On-prem must not overlap `10.0.0.0/12`. The DX gateway
association advertises that single summary as its allowed prefix rather than
each `/16`, so adding a spoke never touches the on-prem side. If on-prem
already uses part of `10.0.0.0/8`, that is decided before any link is ordered,
because renumbering a spoke later is the expensive path.

## Alternatives rejected

| Option | Why not |
| ------ | ------- |
| Build the TGW VPN attachment now behind a flag | About $0.10/hr (VPN connection plus TGW attachment) for two tunnels that stay DOWN with no customer gateway behind them. It shows Terraform syntax, not hybrid routing. Worth building only with a simulated on-prem router (strongSwan or FRR on EC2 in a separate VPC) so BGP actually comes up; that is a separate lab, not a landing zone control. |
| VPN only, no DX | Fine for a small office. Each tunnel tops out around 1.25 Gbps and rides the internet, so latency and throughput are not predictable. ECMP across tunnels on the TGW raises the ceiling but not the predictability. |
| Two DX connections at two locations, no VPN | AWS's high-resiliency model and the right answer when hybrid traffic is business critical. Costs two ports and two circuits all the time. DX plus VPN is the cost-aware middle: the failover path is slower but always there. |
| Virtual private gateway per spoke VPC | One VPN or VIF per VPC multiplies with every spoke and bypasses the inspection VPC entirely. The Transit Gateway already exists to make that one attachment. |

## Consequences

- This repo commits to nothing billable for hybrid. The design costs nothing
  until a link is ordered.
- The commitment it does make is the `10.0.0.0/12` summary. Any new spoke must
  come from inside it, or the on-prem side needs a new advertisement.
- When built, the firewall stops being egress-only. Its rule groups and alarms
  then cover inbound on-prem flows, and an on-prem change can be blocked there
  first, which is the intent.
- Failing over to VPN reduces bandwidth to what the tunnels carry. A workload
  that needs more than that during a DX outage is the signal to move to two DX
  locations.
- Revisit when there is a real on-prem side to connect, or when the simulated
  on-prem lab above gets built.

## Rough cost when built (us-east-1, list prices)

| Piece | Cost |
| ----- | ---- |
| Dedicated DX port, 1 Gbps | about $0.30/hr (~$220/month), plus DX data transfer out (~$0.02/GB) |
| Partner circuit and cross-connect | quoted by the partner, often more than the port |
| Direct Connect gateway | free |
| TGW attachment for the DX gateway | $0.05/hr |
| Site-to-Site VPN connection | $0.05/hr |
| TGW attachment for the VPN | $0.05/hr |
| TGW data processing | $0.02/GB |
