#!/usr/bin/env python3
"""Render architecture.png with mingrammer diagrams and official AWS icons.

Install diagrams and Graphviz, then run python3 docs/diagram.py.
The output path is relative to this source file, independent of the working directory.

The retained, temporary and standby sections share no edges, so Graphviz packs each
as its own component, stacked top to bottom. Edges between them made dot either lay
the sections side by side or crash, so the responder carries its own ops-alarms node.
"""

from pathlib import Path

from diagrams import Cluster, Diagram, Edge
from diagrams.aws.compute import EC2, EKS, EC2ContainerRegistry, EC2ImageBuilder, Fargate, Lambda
from diagrams.aws.database import RDS, Dynamodb
from diagrams.aws.integration import SNS, SQS, StepFunctions
from diagrams.aws.management import (
    Cloudtrail,
    Cloudwatch,
    CloudwatchAlarm,
    CloudwatchEventEventBased,
    Config,
    Organizations,
    OrganizationsAccount,
    SystemsManager,
)
from diagrams.aws.ml import Bedrock
from diagrams.aws.network import Endpoint, InternetGateway, NATGateway, NetworkFirewall, Route53, TransitGateway, VPC
from diagrams.aws.security import Guardduty, IAMPermissions, IAMRole, SingleSignOn
from diagrams.aws.storage import Backup, S3
from diagrams.onprem.ci import GithubActions

RETAINED = {"bgcolor": "#eef6ff", "color": "#7299bd", "fontsize": "17"}
TEMPORARY = {"bgcolor": "#fff4e7", "color": "#d49447", "fontsize": "17"}
EXTERNAL = {"bgcolor": "#f3f3f3", "color": "#8c8c8c", "fontsize": "17"}
ALERT = "#b03a2e"
EGRESS = "#ac6413"

with Diagram(
    "AWS Landing Zone | retained foundation, standing controls and temporary demo\n"
    "Configured relationships; temporary layers, responder and standby were proven then destroyed",
    filename=str(Path(__file__).resolve().with_name("architecture")),
    show=False,
    direction="TB",
    graph_attr={"fontsize": "23", "labelloc": "t", "bgcolor": "white", "pad": "0.5", "nodesep": "1.0", "ranksep": "0.8", "pack": "true", "packmode": "array_u1", "splines": "spline"},
    node_attr={"fontsize": "13"},
    edge_attr={"fontsize": "11"},
):
    with Cluster("GitHub | gated infra pipeline (ADR-0004)", graph_attr=EXTERNAL):
        pipeline = GithubActions("guardrails.yml: PR plan\napply.yml: prod-apply gate\ndestroy.yml: destroy gate")

    with Cluster("RETAIN | organization, accounts and governance", graph_attr=RETAINED):
        with Cluster("Management account", graph_attr=RETAINED):
            org = Organizations("Organization\n8 ACTIVE members")
            controls = IAMPermissions("SCPs + tag policy\nEC2 declarative policy\nRAM org sharing")
            identity = SingleSignOn("Identity Center\noptional")
            trail = Cloudtrail("Organization\ntrail, all\nmembers")
            ci_roles = IAMRole("gha-plan +\ngha-apply, one\nrole each in\nnetwork, prod")
            state = S3("Terraform state\nKMS / versioned\nprevent_destroy")
            org >> Edge(label="member policy") >> controls
            org >> Edge(style="dotted") >> identity
            ci_roles >> Edge(label="state + S3 lockfile") >> state

        pipeline >> Edge(label="OIDC, immutable subject") >> ci_roles

        with Cluster("Security account", graph_attr=RETAINED):
            guardduty = Guardduty("GuardDuty\ndelegated\nadmin")
            config = Config("AWS Config\nconformance\npack")
            findings = CloudwatchEventEventBased("Finding alerts\nEventBridge / SNS")
            guardduty >> Edge(style="dashed") >> findings
            scanner = Lambda("Secrets\nscanner, 90-day\nage alarms")
            forensics = StepFunctions("Forensics runbook\nisolate, snapshot, revoke")
            findings >> Edge(style="dashed", label="GuardDuty finding") >> forensics

        with Cluster("Log-archive account", graph_attr=RETAINED):
            bucket = S3("KMS-encrypted logs\nObject Lock")

        trail >> bucket

        with Cluster("Shared-services account | observability and standing controls", graph_attr=RETAINED):
            monitoring = Cloudwatch("OAM sink + central alarms\nprod and network links")
            ops = SNS("ops-alarms topic\nKMS / email")
            reader = IAMRole("Incident alarm reader\ntrusts the responder's\nremediate role")
            monitoring >> Edge(color=ALERT) >> ops

            with Cluster("uptime/ | every 5 minutes", graph_attr=RETAINED):
                uptime = Lambda("Uptime checker\njordandesigns.io\nstatus / body / cert")
                uptime_log = Dynamodb("Check log\n90-day TTL")
                uptime_alarms = CloudwatchAlarm("Site down / latency\ncert expiry alarms")
                uptime >> uptime_log
                uptime >> Edge(label="metrics") >> uptime_alarms

            with Cluster("backup-verify/ | retained landing bucket", graph_attr=RETAINED):
                heartbeat = Lambda("Heartbeat producer\nevery 6 hours\nsynthetic object")
                landing = S3("Landing bucket\nKMS / versioned\nprevent_destroy")
                checker = Lambda("Freshness checker\ndaily 08:00 UTC\nnewest-object age")
                stale = CloudwatchAlarm("Stale backup alarm\nover 30 hours\nfreshness_alarm_enabled")
                heartbeat >> Edge(label="PutObject\nSSE-KMS header") >> landing
                checker >> Edge(style="dashed", label="list") >> landing
                checker >> Edge(label="age metric") >> stale

            uptime_alarms >> Edge(color=ALERT) >> ops
            stale >> Edge(color=ALERT) >> ops

        with Cluster("Prod account | retained controls", graph_attr=RETAINED):
            with Cluster("remediation/ | dry run by default", graph_attr=RETAINED):
                cpu = CloudwatchAlarm("High-CPU alarm\nper monitored instance\nnone monitored today")
                remediate_fn = Lambda("Remediation\nreboot behind cooldown\n+ circuit breaker")
                remediate_state = Dynamodb("Attempt state\nconditional write")
                remediate_topics = SNS("Alerts + on-call\ntopics")
                cpu >> Edge(label="EventBridge") >> remediate_fn
                remediate_fn >> remediate_state
                remediate_fn >> Edge(color=ALERT, label="notice / page once") >> remediate_topics
            mirror = EC2ContainerRegistry("n8n image mirror\npinned by digest")

        other_accounts = OrganizationsAccount("Dev / test / sandbox\naccounts; no VPCs")
        scanner >> Edge(style="dashed", label="metadata-only\nscan roles, all members") >> other_accounts

    with Cluster("TEMPORARY | destroy responder, delivery and compute first, then workload, network last", graph_attr=TEMPORARY):
        with Cluster("network/ | network account | us-east-1", graph_attr=TEMPORARY):
            tgw = TransitGateway("RAM-shared TGW\nspoke + inspection tables\nprod egress + inspected return")
            with Cluster("Inspection VPC | 10.0.0.0/16 | single-AZ demo", graph_attr=TEMPORARY):
                firewall = NetworkFirewall("Network Firewall\ndomain allowlist")
                nat = NATGateway("Hub NAT")
                internet = InternetGateway("Internet gateway")
                hub_endpoints = Endpoint("Hub private endpoints\n+ S3 gateway")
                tgw >> Edge(label="inspected egress", color=EGRESS) >> firewall
                firewall >> nat >> internet

        with Cluster("workload/, compute/ and delivery/ | prod account | us-east-1", graph_attr=TEMPORARY):
            with Cluster("Private VPC | 10.3.0.0/16 | no local NAT or IGW", graph_attr=TEMPORARY):
                prod = VPC("Prod spoke\nexplicit acceptance")
                eks = EKS("EKS private API\n2 AL2023 nodes\nIRSA")
                endpoints = Endpoint("Prod private endpoints\n+ S3 and DynamoDB gateways")
                rds = RDS("PostgreSQL\nprivate / encrypted / Multi-AZ")
                prod >> Edge(style="dotted", label="hosts") >> eks
                eks >> Edge(label="private AWS APIs") >> endpoints
                eks >> Edge(style="dotted", label="SG permits TCP 5432") >> rds
                with Cluster("App subnet | 10.3.20.0/24 | compute/", graph_attr=TEMPORARY):
                    mgmt = EC2("Management instance\ngolden AMI / no public IP\nIMDSv2 / no SSH key")
                mgmt >> Edge(label="Session Manager\n+ patching") >> endpoints

            registry = EC2ContainerRegistry("ECR\nimmutable tags / scanning")
            backup = Backup("Local daily backup\nVault Lock grace period")
            registry >> Edge(style="dashed", label="image source") >> eks
            golden = EC2ImageBuilder("Golden AMI\npipeline, STIG +\ncis_baseline,\ntested after reboot")
            patching = SystemsManager("SSM patch\nbaseline, Default\nHost Management")
            golden >> Edge(style="dashed", label="boots from") >> mgmt
            patching >> Edge(style="dashed", label="Patch Group = prod") >> mgmt
            rds >> Edge(style="dashed", label="backup selection") >> backup

            with Cluster("Incident responder | relay, n8n and remediate run in the VPC app subnets (proven, destroyed)", graph_attr=TEMPORARY):
                ops_in = SNS("ops-alarms topic\nin shared-services")
                queue = SQS("Ops queue + DLQ\nKMS")
                relay = Lambda("Relay Lambda")
                n8n = Fargate("n8n on Fargate\nprivate, Cloud Map")
                responder_fix = Lambda("Remediate Lambda\nsummarize / notify / act\nRDS failover, node scale")
                summary = Bedrock("Amazon Nova Lite\nConverse, in-region")
                ops_in >> Edge(color=ALERT, label="SQS subscription") >> queue
                queue >> relay >> n8n
                n8n >> Edge(label="invoke, Lambda API\nvia firewall") >> responder_fix
                responder_fix >> Edge(label="summary") >> summary
                responder_fix >> Edge(color=ALERT, style="dashed", label="one notice") >> ops_in

            with Cluster("delivery/ | release-guard support", graph_attr=TEMPORARY):
                deploy_role = IAMRole("GitHub OIDC\nroles, publish +\npromote, shared\nboundary")
                app_registry = EC2ContainerRegistry("Delivery ECR\napp, deploy,\nverifier, Flux\nKMS")
                deployments = Dynamodb("Deployments table\nrecords, verdicts\noverride grants")
                irsa = IAMRole("IRSA roles\nFlux source,\nverifier, orders-api,\nmigrator")
                deploy_role >> app_registry
                deploy_role >> deployments
                irsa >> Edge(style="dashed", label="Flux pulls") >> app_registry

        prod >> Edge(color=EGRESS, constraint="false") >> tgw
        responder_fix >> Edge(style="dotted", color=EGRESS, label="Bedrock and RDS APIs\nvia firewall allowlist", constraint="false") >> firewall

    with Cluster("TEMPORARY | standby/ | prod account | us-west-2 warm standby (proven, destroyed)", graph_attr=TEMPORARY):
        dns = Route53("Route 53 failover\nhealth check on primary")
        replica = RDS("Cross-region replica of prod RDS\nmulti-region KMS")
        promote = Lambda("Promote Lambda\nalarm crosses regions")
        dns >> Edge(label="alarm") >> promote
        promote >> Edge(label="PromoteReadReplica") >> replica
