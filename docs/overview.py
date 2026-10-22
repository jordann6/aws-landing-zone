#!/usr/bin/env python3
"""Render overview.png, the one-screen view at the top of the README.

Install diagrams and Graphviz, then run python3 docs/overview.py.
docs/diagram.py renders the full inventory (architecture.png).
"""

from pathlib import Path

from diagrams import Cluster, Diagram, Edge
from diagrams.aws.compute import EKS
from diagrams.aws.database import RDS
from diagrams.aws.management import Cloudtrail, Organizations
from diagrams.aws.network import InternetGateway, NATGateway, NetworkFirewall, TransitGateway
from diagrams.aws.security import Guardduty
from diagrams.aws.storage import S3
from diagrams.onprem.ci import GithubActions

RETAINED = {"bgcolor": "#eef6ff", "color": "#7299bd", "fontsize": "15"}
TEMPORARY = {"bgcolor": "#fff4e7", "color": "#d49447", "fontsize": "15"}
EGRESS = "#ac6413"

with Diagram(
    "AWS Landing Zone | overview",
    filename=str(Path(__file__).with_name("overview")),
    outformat="png",
    show=False,
    direction="LR",
    graph_attr={"fontsize": "20", "pad": "0.4", "nodesep": "0.6", "ranksep": "0.9"},
):
    ci = GithubActions("Gated pipeline\nread-only plan on PR\nreviewed apply / destroy")

    with Cluster("Retained | management, security, log-archive", graph_attr=RETAINED):
        org = Organizations("Organization\n8 accounts, SCPs")
        trail = Cloudtrail("Org trail")
        logs = S3("Object Lock\nlog archive")
        gd = Guardduty("GuardDuty\ndelegated admin")

    with Cluster("Temporary | prod account, no NAT or IGW", graph_attr=TEMPORARY):
        eks = EKS("Private EKS")
        db = RDS("Multi-AZ\nPostgreSQL")

    with Cluster("Temporary | network account", graph_attr=TEMPORARY):
        tgw = TransitGateway("Shared TGW")
        fw = NetworkFirewall("Network Firewall\ndomain allowlist")
        nat = NATGateway("Hub NAT")
        igw = InternetGateway("Internet")

    ci >> Edge(label="builds, then destroys") >> eks
    trail >> logs
    org - trail
    org - gd
    eks >> db
    eks >> Edge(color=EGRESS) >> tgw >> Edge(color=EGRESS) >> fw >> Edge(color=EGRESS) >> nat >> Edge(color=EGRESS) >> igw
