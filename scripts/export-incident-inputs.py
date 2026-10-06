#!/usr/bin/env python3
"""Export landing zone inputs for the incident tooling to private variable files.

forensics  -> aws-incident-forensics/terraform/lz/lz.tfvars.json (security account)
responder  -> aws-incident-responder/terraform/lz/lz.tfvars.json (prod account)

Values come from Terraform outputs of the incident/, observability/ and (for the
responder) workload/ roots, so no account id is typed by hand. Files are
written mode 0600 and are gitignored in both repositories: they hold account
ids and role ARNs.
"""

import argparse
import json
import os
from pathlib import Path
import re
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[1]
STEPS = (
    "extract-context", "isolate-instance", "snapshot-evidence", "encrypt-snapshots",
    "check-snapshots", "revoke-credentials", "collect-evidence",
)
DEPLOY_ROLE = r"arn:aws:iam::[0-9]{12}:role/OrganizationAccountAccessRole"


def outputs(root):
    raw = subprocess.check_output(["terraform", f"-chdir={ROOT / root}", "output", "-json"])
    return {k: v["value"] for k, v in json.loads(raw).items()}


def require(value, pattern, what):
    if not isinstance(value, str) or not re.fullmatch(pattern, value):
        raise SystemExit(f"{what} is missing or malformed; apply its root first")
    return value


def forensics_inputs(alert_email):
    inc = outputs("incident")
    obs = outputs("observability")
    roles = inc.get("forensics_target_role_arns") or {}
    if sorted(roles) != sorted(STEPS):
        raise SystemExit("incident/ has no complete set of forensics target roles; apply it first")
    for arn in roles.values():
        require(arn, r"arn:aws:iam::[0-9]{12}:role/forensics/forensics-[a-z-]+", "forensics target role")
    variables = {
        "deploy_role_arn": require(inc.get("forensics_deploy_role_arn"), DEPLOY_ROLE, "forensics deploy role"),
        "target_role_arns": {require(inc.get("prod_account_id"), r"[0-9]{12}", "prod account id"): roles},
        "findings_topic_arn": require(obs.get("security_findings_topic_arn"),
                                      r"arn:aws:sns:[a-z0-9-]+:[0-9]{12}:security-findings", "findings topic"),
    }
    if alert_email:
        variables["alert_email"] = alert_email
    return variables


def responder_inputs(n8n_digest):
    inc = outputs("incident")
    obs = outputs("observability")
    work = outputs("workload")
    digest = require(n8n_digest, r"sha256:[0-9a-f]{64}", "--n8n-digest")
    repo = require(inc.get("n8n_repository_url"),
                   r"[0-9]{12}\.dkr\.ecr\.[a-z0-9-]+\.amazonaws\.com/incident-responder/n8n", "n8n repository")
    subnets = work.get("app_subnet_ids") or []
    if not subnets:
        raise SystemExit("workload/ has no app subnets; deploy the workload first")
    variables = {
        "deploy_role_arn": require(inc.get("responder_deploy_role_arn"), DEPLOY_ROLE, "responder deploy role"),
        "vpc_id": require(work.get("prod_vpc_id"), r"vpc-[0-9a-f]+", "prod VPC"),
        "app_subnet_ids": subnets,
        "ops_topic_arn": require(obs.get("ops_topic_arn"), r"arn:aws:sns:[a-z0-9-]+:[0-9]{12}:ops-alarms", "ops topic"),
        "ops_topic_kms_key_arn": require(obs.get("ops_topic_kms_key_arn"),
                                         r"arn:aws:kms:[a-z0-9-]+:[0-9]{12}:key/[0-9a-f-]+", "ops topic key"),
        "alarm_reader_role_arn": require(inc.get("alarm_reader_role_arn"),
                                         r"arn:aws:iam::[0-9]{12}:role/incident-alarm-reader", "alarm reader role"),
        "known_alarms": obs.get("alarm_names") or [],
        "n8n_image": f"{repo}@{digest}",
    }
    for key, output in (("rds_instance_id", "rds_instance_id"), ("eks_cluster_name", "eks_cluster_name"),
                        ("eks_node_group_name", "eks_node_group_name")):
        if work.get(output):
            variables[key] = work[output]
    if not variables["known_alarms"]:
        raise SystemExit("observability/ reports no central alarms")
    return variables


def write(destination, variables):
    destination.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(mode="w", dir=destination.parent, delete=False) as f:
        json.dump(variables, f, indent=2)
        f.write("\n")
        temporary = f.name
    os.chmod(temporary, 0o600)
    os.replace(temporary, destination)


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    sub = parser.add_subparsers(dest="target", required=True)
    f = sub.add_parser("forensics")
    f.add_argument("--destination", type=Path,
                   default=ROOT.parent / "aws-incident-forensics/terraform/lz/lz.tfvars.json")
    f.add_argument("--alert-email", help="optional address for [CONTAINED] / [FAILED] notices")
    r = sub.add_parser("responder")
    r.add_argument("--destination", type=Path,
                   default=ROOT.parent / "aws-incident-responder/terraform/lz/lz.tfvars.json")
    r.add_argument("--n8n-digest", required=True, help="digest of the n8n image copied into the ECR repository")
    args = parser.parse_args()

    if args.target == "forensics":
        variables = forensics_inputs(args.alert_email)
    else:
        variables = responder_inputs(args.n8n_digest)
    write(args.destination, variables)
    print(f"Exported {len(variables)} {args.target} inputs to a mode-0600 variable file.")


if __name__ == "__main__":
    main()
