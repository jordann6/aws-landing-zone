# ADR-0002: EKS workload metrics through Container Insights, not a Prometheus stack

- **Status:** accepted
- **Date:** 2026-10-04

## Context

The landing zone had EKS control plane logs but no workload metrics, so nothing
could alarm on a failed node or a crash-looping pod. Phase A centralizes alarms
in a monitoring account (shared-services) over CloudWatch cross-account
observability (OAM), and every other signal it alarms on (RDS, Network
Firewall, AWS Backup) is already a CloudWatch metric.

Constraints that bind:

- One operator, and a deploy/demo/destroy posture: the stack is up for a few
  hours at a time, then torn down. Anything that needs tuning, storage, or
  upgrades between demos is pure overhead.
- Nodes have no internet path except the firewall allowlist, so every
  dependency is either a VPC endpoint or an allowlisted domain.
- The alarms must live in the monitoring account and read from source accounts,
  not inside the cluster they watch.

## Decision

Run the managed `amazon-cloudwatch-observability` EKS add-on (Container
Insights), with its service account on an IRSA role. Its metrics land in
CloudWatch in the prod account, reach the monitoring account through the
existing OAM link, and drive the central `eks-failed-nodes` alarm like any other
metric.

## Alternatives rejected

| Option | Why not |
| ------ | ------- |
| Reuse `observability-stack` (Prometheus, Grafana, AlertManager on EKS) | A second alerting plane. Its alerts would live in the cluster they watch and route through AlertManager, separate from the OAM alarms everything else uses. It also adds pods, a persistent volume, and Grafana to the 1-node demo cluster, and its images need allowlisting. |
| Amazon Managed Service for Prometheus + Managed Grafana | Removes the in-cluster storage, but still a second query language and alerting path beside CloudWatch, plus a workspace and scraper to stand up and tear down every session. |
| No workload metrics (control plane logs only) | Cannot detect a failed node, which is exactly the remediation Phase D automates (scale the node group, restart the deployment). |

The simpler option, no workload metrics, was not enough because Phase D needs a
node-health signal to act on.

## Consequences

- One alarm plane: every alarm is a CloudWatch alarm in the monitoring account
  on the ops topic, so the incident responder has a single input.
- Phase D's "AlertManager also feeds n8n" path drops out; nothing is lost
  because the same signals arrive on the ops topic.
- Cost is per metric and log ingestion while the cluster runs, and zero when it
  is torn down. The prod VPC gains a `monitoring` interface endpoint.
- PromQL-style ad hoc queries and Grafana dashboards are not available out of
  the box. Revisit if the platform grows to many clusters or teams that already
  run Prometheus, where `observability-stack` (with AMP as the store) becomes
  the better shared path.
