#!/usr/bin/env python3
"""Architecture diagram for the AWS landing zone.

Renders docs/architecture.png with the mingrammer `diagrams` library using the
official AWS service icons. Regenerate with:

    pip install diagrams   # needs graphviz (`brew install graphviz`)
    python docs/diagram.py
"""

from diagrams import Cluster, Diagram, Edge
from diagrams.aws.management import Organizations, OrganizationsOrganizationalUnit, Cloudtrail, Config
from diagrams.aws.security import SecurityHub, Guardduty, KMS, SingleSignOn, IAMPermissions
from diagrams.aws.storage import S3
from diagrams.aws.network import TransitGateway, NATGateway, VPC, Endpoint, NetworkFirewall
from diagrams.aws.general import Users
from diagrams.aws.cost import CostExplorer
from diagrams.aws.compute import EKS, EC2ContainerRegistry
from diagrams.aws.database import RDS
from diagrams.aws.storage import Backup

graph_attr = {
    "fontsize": "20",
    "labelloc": "t",
    "bgcolor": "white",
    "pad": "0.5",
}

with Diagram(
    "AWS Landing Zone",
    filename="docs/architecture",
    show=False,
    direction="TB",
    graph_attr=graph_attr,
):
    people = Users("Federated workforce")

    with Cluster("AWS Organization (management account)"):
        org = Organizations("Organizations")

        with Cluster("Preventive guardrails (inherited)"):
            guardrails = [
                IAMPermissions("SCPs"),
                Config("Tag policy"),
                CostExplorer("Budgets + anomaly"),
            ]

        idc = SingleSignOn("IAM Identity Center\npersonas")

        with Cluster("Security OU"):
            with Cluster("security account (delegated admin)"):
                sec = [
                    SecurityHub("Security Hub\nCIS 1.4.0"),
                    Guardduty("GuardDuty"),
                    Config("AWS Config"),
                ]

        with Cluster("Infrastructure OU"):
            with Cluster("log-archive account"):
                trail = Cloudtrail("Org CloudTrail")
                log_bucket = S3("Object-Lock\nWORM bucket")
                cmk = KMS("Logging CMK\n(rotation)")
                trail >> Edge(label="encrypted") >> log_bucket
                cmk >> Edge(style="dashed") >> log_bucket

            with Cluster("network account"):
                tgw = TransitGateway("Transit Gateway\n(RAM shared)")
                with Cluster("Egress / inspection VPC (10.0.0.0/16)"):
                    fw = NetworkFirewall("Network Firewall\n(default-deny)")
                    nat = NATGateway("NAT")
                    endpoints = Endpoint("Private endpoints\nSSM / ECR / Secrets / Logs")
                    tgw >> Edge(label="all egress") >> fw >> nat

        with Cluster("Workloads OU"):
            dev = VPC("dev\n10.1/16")
            test = VPC("test\n10.2/16")
            prod = VPC("prod\n10.3/16")

        with Cluster("Sandbox OU"):
            sandbox = VPC("sandbox\n10.4/16")

        with Cluster("Prod paved road (workload account)"):
            eks = EKS("EKS\nprivate API, IRSA")
            rds = RDS("RDS PostgreSQL\nMulti-AZ, CMK")
            ecr = EC2ContainerRegistry("ECR\nscan + pull-through")
            vault = Backup("Backup Vault Lock\n(WORM) + DR copy")
            eks >> Edge(style="dotted", label="app only") >> rds
            rds >> Edge(style="dashed", color="firebrick") >> vault

    # Relationships
    people >> Edge(label="SSO") >> idc
    org >> guardrails
    org >> idc
    [dev, test, prod, sandbox] >> Edge(color="darkgreen", label="spoke -> TGW") >> tgw
    [dev, test, prod, sandbox] >> Edge(style="dotted", color="gray") >> endpoints
    prod >> Edge(label="paved road") >> eks
    ecr >> Edge(style="dotted", color="gray", label="private pulls") >> endpoints
    prod >> Edge(style="dashed", color="firebrick", label="audit") >> trail
