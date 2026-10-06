#!/usr/bin/env python3
"""Render architecture.png with mingrammer diagrams and official AWS icons.

Install diagrams and Graphviz, then run python3 docs/diagram.py.
The output path is relative to this source file, independent of the working directory.
"""

from pathlib import Path

from diagrams import Cluster, Diagram, Edge
from diagrams.aws.compute import EC2, EKS, EC2ContainerRegistry, EC2ImageBuilder
from diagrams.aws.database import RDS
from diagrams.aws.management import (
    Cloudtrail,
    Cloudwatch,
    CloudwatchEventEventBased,
    Config,
    Organizations,
    OrganizationsAccount,
    SystemsManager,
)
from diagrams.aws.network import Endpoint, InternetGateway, NATGateway, NetworkFirewall, TransitGateway, VPC
from diagrams.aws.security import Guardduty, IAMPermissions, SingleSignOn
from diagrams.aws.storage import Backup, S3

RETAINED = {"bgcolor": "#eef6ff", "color": "#7299bd", "fontsize": "17"}
TEMPORARY = {"bgcolor": "#fff4e7", "color": "#d49447", "fontsize": "17"}

with Diagram(
    "AWS Landing Zone | retained foundation and temporary demo\n"
    "Configured relationships; no application deployed; cross-region backup disabled",
    filename=str(Path(__file__).resolve().with_name("architecture")),
    show=False,
    direction="TB",
    graph_attr={"fontsize": "23", "labelloc": "t", "bgcolor": "white", "pad": "0.5", "nodesep": "0.8", "ranksep": "0.8", "pack": "true", "packmode": "array_u1", "splines": "spline"},
    node_attr={"fontsize": "13"},
    edge_attr={"fontsize": "11"},
):
    with Cluster("RETAIN | organization, accounts and governance", graph_attr=RETAINED):
        with Cluster("Management account", graph_attr=RETAINED):
            org = Organizations("Organization\n8 ACTIVE members")
            controls = IAMPermissions("SCPs + tag policy\nEC2 declarative policy\nRAM org sharing")
            identity = SingleSignOn("Identity Center\noptional")
            org >> Edge(label="member policy") >> controls
            org >> Edge(style="dotted") >> identity

        with Cluster("Security account", graph_attr=RETAINED):
            guardduty = Guardduty("GuardDuty\ndelegated admin")
            config = Config("AWS Config")
            findings = CloudwatchEventEventBased("Finding alerts\nEventBridge / SNS")
            guardduty >> Edge(style="dashed") >> findings

        with Cluster("Log-archive account", graph_attr=RETAINED):
            trail = Cloudtrail("Organization audit\nall member accounts")
            bucket = S3("KMS-encrypted logs\nObject Lock")
            trail >> bucket

        with Cluster("Shared-services account | retained observability", graph_attr=RETAINED):
            monitoring = Cloudwatch("OAM + central alarms\nprod and network sources")

        other_accounts = OrganizationsAccount("Dev / test / sandbox\naccounts; no VPCs")

    with Cluster("TEMPORARY | workload first, network second", graph_attr=TEMPORARY):
        with Cluster("TEAR DOWN SECOND | network account | us-east-1", graph_attr=TEMPORARY):
            tgw = TransitGateway("RAM-shared TGW\nspoke + inspection tables")
            with Cluster("Inspection VPC | 10.0.0.0/16 | single-AZ demo", graph_attr=TEMPORARY):
                firewall = NetworkFirewall("Network Firewall\ndomain allowlist")
                nat = NATGateway("Hub NAT")
                internet = InternetGateway("Internet gateway")
                hub_endpoints = Endpoint("Hub private endpoints\n+ S3 gateway")
                tgw >> Edge(label="inspected egress", color="#ac6413") >> firewall
                firewall >> nat >> internet

        with Cluster("TEAR DOWN FIRST | prod account | us-east-1", graph_attr=TEMPORARY):
            with Cluster("Private VPC | 10.3.0.0/16 | no local NAT or IGW", graph_attr=TEMPORARY):
                prod = VPC("Prod spoke\nexplicit acceptance")
                eks = EKS("EKS private API\n2 AL2023 nodes / IRSA")
                endpoints = Endpoint("Prod private endpoints\n+ S3 gateway")
                rds = RDS("PostgreSQL\nprivate / encrypted / Multi-AZ")
                prod >> Edge(style="dotted", label="hosts") >> eks
                eks >> Edge(label="private AWS APIs") >> endpoints
                eks >> Edge(style="dotted", label="SG permits TCP 5432") >> rds
                with Cluster("App subnet | 10.3.20.0/24", graph_attr=TEMPORARY):
                    mgmt = EC2("Management instance\ngolden AMI / no public IP\nIMDSv2 / no SSH key")
                mgmt >> Edge(label="Session Manager\n+ patching") >> endpoints

            registry = EC2ContainerRegistry("ECR\nimmutable tags / scanning")
            backup = Backup("Local daily backup\nVault Lock grace period")
            registry >> Edge(style="dashed", label="image source") >> eks
            golden = EC2ImageBuilder("Golden AMI pipeline\nSTIG + cis_baseline\ntested after reboot")
            patching = SystemsManager("SSM patch baseline\nDefault Host Management")
            golden >> Edge(style="dashed", label="boots from") >> mgmt
            patching >> Edge(style="dashed", label="Patch Group = prod") >> mgmt
            rds >> Edge(style="dashed", label="backup selection") >> backup

        prod >> Edge(color="#ac6413", label="egress + inspected return", constraint="false") >> tgw
