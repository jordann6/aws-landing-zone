# Containment for the forensics runbook. An instance under investigation has
# every network interface moved onto this group: no ingress and no egress, so
# it can neither be reached nor call out (SSM included), but it keeps running
# and its memory survives for analysis. Declaring no egress block makes
# Terraform remove the default allow-all rule. The runbook finds the group by
# its lz:quarantine tag in the instance's VPC, so it carries no per-account
# configuration.
resource "aws_security_group" "quarantine" {
  #checkov:skip=CKV2_AWS_5:Attached at incident time by the forensics runbook, never at deploy time.
  name        = "prod-quarantine"
  description = "Forensics isolation: no ingress, no egress"
  vpc_id      = aws_vpc.prod.id

  tags = {
    Name            = "prod-quarantine"
    "lz:quarantine" = "true"
  }
}
