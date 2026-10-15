# Copy to terraform.tfvars (gitignored) and fill in.
owner           = "you"
cost_center     = "cc-0000"
prod_account_id = "000000000000"

# Set false if a GitHub Actions OIDC provider already exists in the prod account.
create_github_oidc_provider = true
