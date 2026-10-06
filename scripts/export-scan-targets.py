#!/usr/bin/env python3
"""Export the scanner's landing zone inputs to a private Terraform variable file."""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--plan", action="store_true", help="Read the saved secrets/tfplan before its apply")
    parser.add_argument("--destination", required=True, type=Path)
    args = parser.parse_args()
    root = Path(__file__).resolve().parents[1] / "secrets"
    if args.plan:
        command = ["terraform", f"-chdir={root}", "show", "-json", "tfplan"]
        plan = json.loads(subprocess.check_output(command))
        outputs = {k: v["value"] for k, v in plan["planned_values"]["outputs"].items()}
    else:
        command = ["terraform", f"-chdir={root}", "output", "-json"]
        outputs = {k: v["value"] for k, v in json.loads(subprocess.check_output(command)).items()}
    arns = outputs.get("scan_target_role_arns")
    deploy_role = outputs.get("scanner_deploy_role_arn")
    if not arns or any(not re.fullmatch(r"arn:aws:iam::[0-9]{12}:role/[a-z0-9-]+-scan-target-role", arn) for arn in arns):
        raise ValueError("No complete scan-target output is available")
    if not deploy_role or not re.fullmatch(r"arn:aws:iam::[0-9]{12}:role/OrganizationAccountAccessRole", deploy_role):
        raise ValueError("No scanner deploy role output is available")
    # The security account is the Security Hub delegated admin, so the scanner
    # must not manage enablement there, and the dashboard stays private.
    variables = {
        "scan_target_role_arns": arns,
        "deploy_role_arn": deploy_role,
        "manage_securityhub": False,
        "public_dashboard": False,
    }
    args.destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=args.destination.parent, delete=False) as f:
        json.dump(variables, f, indent=2)
        f.write("\n")
        temporary = f.name
    os.replace(temporary, args.destination)
    print(f"Exported {len(arns)} scan targets and the security-account deploy role to a mode-0600 variable file.")


if __name__ == "__main__":
    main()
