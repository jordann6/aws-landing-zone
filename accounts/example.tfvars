# Copy to terraform.tfvars (gitignored) and fill in. terraform.tfvars holds the
# environment-specific and sensitive values; this template is safe to commit.

# REQUIRED. Plus-addressable base for globally-unique member-account emails. Each
# account is derived as <local>+<name>@<domain>, e.g. security becomes
# you+aws+security@example.com. Must not collide with any existing (including
# suspended) account email in the org.
org_email_domain = "you+aws@example.com"

# --- Reduced-footprint toggles (canonical design leaves both true) ------------
#   full_account_set  : false = create only security/log-archive/sandbox
#                       (use when the org is at its account-count limit)
#   enable_tag_policy : false = TAG_POLICY type/doc not ready
# full_account_set  = true
# enable_tag_policy = true

# --- Other optional overrides (defaults shown) --------------------------------
# region          = "us-east-1"
# allowed_regions = ["us-east-1"]
