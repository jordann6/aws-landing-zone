# Inputs read from upstream state instead of a hand-written tfvars file
# (ADR-0004), so CI and the operator plan from the same source of truth. A
# variable set explicitly still wins, which keeps phase-c.tfvars.json working.

data "terraform_remote_state" "accounts" {
  backend = "s3"
  config = {
    bucket = "jordann6-aws-landing-zone-tfstate"
    key    = "aws-landing-zone/accounts.tfstate"
    region = "us-east-1"
  }
}

data "terraform_remote_state" "network" {
  backend = "s3"
  config = {
    bucket = "jordann6-aws-landing-zone-tfstate"
    key    = "aws-landing-zone/network.tfstate"
    region = "us-east-1"
  }
  lifecycle {
    postcondition {
      condition     = !var.enable_tgw || var.transit_gateway_id != null || try(self.outputs.transit_gateway_id, null) != null
      error_message = "enable_tgw requires a live transit_gateway_id: apply the network root first, or set enable_tgw = false."
    }
  }
}

locals {
  prod_account_id    = coalesce(var.prod_account_id, data.terraform_remote_state.accounts.outputs.prod_account_id)
  network_account_id = coalesce(var.network_account_id, data.terraform_remote_state.accounts.outputs.network_account_id)
  transit_gateway_id = var.transit_gateway_id != null ? var.transit_gateway_id : try(data.terraform_remote_state.network.outputs.transit_gateway_id, null)
}

# The account's EBS encryption default is owned by the Workloads OU declarative
# policy, and the require-encrypted-ebs SCP denies turning it off, so this root
# must never try to destroy it. It left the code in ec1f60c; this block is the
# declarative replacement for the old manual `terraform state rm` before a
# destroy: if any state still tracks it, Terraform forgets it without touching
# the real setting. (Terraform 1.7 or later.)
removed {
  from = aws_ebs_encryption_by_default.this

  lifecycle {
    destroy = false
  }
}
