#!/usr/bin/env python3
"""Export metadata-role ARNs to a private scanner Terraform variable file."""

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
        arns = plan["planned_values"]["outputs"]["scan_target_role_arns"]["value"]
    else:
        command = ["terraform", f"-chdir={root}", "output", "-json", "scan_target_role_arns"]
        arns = json.loads(subprocess.check_output(command))
    if not arns or any(not re.fullmatch(r"arn:aws:iam::[0-9]{12}:role/[a-z0-9-]+-scan-target-role", arn) for arn in arns):
        raise ValueError("No complete scan-target output is available")
    args.destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=args.destination.parent, delete=False) as f:
        json.dump({"scan_target_role_arns": arns}, f, indent=2)
        f.write("\n")
        temporary = f.name
    os.replace(temporary, args.destination)
    print(f"Exported {len(arns)} scan targets to a mode-0600 variable file.")


if __name__ == "__main__":
    main()
