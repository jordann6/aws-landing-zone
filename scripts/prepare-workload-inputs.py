#!/usr/bin/env python3
"""Prepare private landing-zone inputs from existing Terraform state metadata."""

import argparse
import json
import os
from pathlib import Path
import re
import tempfile


def write_private(path, values):
    with tempfile.NamedTemporaryFile(mode="w", dir=path.parent, delete=False) as handle:
        json.dump(values, handle, indent=2)
        handle.write("\n")
        temporary = handle.name
    os.replace(temporary, path)


def main():
    import boto3

    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--workload", action="store_true", help="Require the deployed network and prepare workload inputs")
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1]
    session = boto3.Session(region_name="us-east-1")
    owner = session.client("sts").get_caller_identity()["Account"]
    s3 = session.client("s3")

    def outputs(name):
        obj = s3.get_object(
            Bucket="jordann6-aws-landing-zone-tfstate", Key=f"aws-landing-zone/{name}.tfstate",
            ExpectedBucketOwner=owner,
        )
        document = json.loads(obj["Body"].read())
        return {key: item["value"] for key, item in document["outputs"].items()}

    accounts = outputs("accounts")
    if not accounts.get("ram_organization_sharing_enabled"):
        raise ValueError("Apply the persistent accounts RAM-sharing prerequisite first")
    for key in ["network_account_id", "prod_account_id"]:
        if not re.fullmatch(r"[0-9]{12}", str(accounts.get(key, ""))):
            raise ValueError("Persistent account outputs are incomplete")
    write_private(root / "network/phase-c.tfvars.json", {
        "network_account_id": accounts["network_account_id"],
        "org_arn": accounts["organization_arn"],
    })
    if args.workload:
        network = outputs("network")
        tgw = network.get("transit_gateway_id", "")
        if not re.fullmatch(r"tgw-[0-9a-f]+", tgw):
            raise ValueError("Deploy the reviewed network plan before preparing workload inputs")
        write_private(root / "workload/phase-c.tfvars.json", {
            "prod_account_id": accounts["prod_account_id"],
            "network_account_id": accounts["network_account_id"],
            "transit_gateway_id": tgw,
        })
    print("Prepared mode-0600, gitignored deployment inputs from existing state.")


if __name__ == "__main__":
    main()
