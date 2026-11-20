# The member accounts moved from one resource block each (count-gated where they
# depend on full_account_set) to a single for_each over local.accounts. These
# blocks carry the existing accounts to their new addresses, so the refactor
# plans as 8 moves and nothing else. Keep them: removing a moved block is safe
# only once every state that held the old addresses has been migrated.
moved {
  from = aws_organizations_account.sandbox
  to   = aws_organizations_account.this["sandbox"]
}

moved {
  from = aws_organizations_account.dev[0]
  to   = aws_organizations_account.this["dev"]
}

moved {
  from = aws_organizations_account.test[0]
  to   = aws_organizations_account.this["test"]
}

moved {
  from = aws_organizations_account.prod[0]
  to   = aws_organizations_account.this["prod"]
}

moved {
  from = aws_organizations_account.security
  to   = aws_organizations_account.this["security"]
}

moved {
  from = aws_organizations_account.network[0]
  to   = aws_organizations_account.this["network"]
}

moved {
  from = aws_organizations_account.shared_services[0]
  to   = aws_organizations_account.this["shared-services"]
}

moved {
  from = aws_organizations_account.log_archive
  to   = aws_organizations_account.this["log-archive"]
}
