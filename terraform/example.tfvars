# Copy to terraform.tfvars (gitignored) and fill in. terraform.tfvars holds the
# environment-specific and sensitive values; this template is safe to commit.

# REQUIRED. Plus-addressable base for globally-unique member-account emails. Each
# account is derived as <local>+<name>@<domain>, e.g. security becomes
# you+aws+security@example.com. Must not collide with any existing (including
# suspended) account email in the org.
org_email_domain = "you+aws@example.com"

# REQUIRED. Where budget and cost-anomaly alerts are delivered.
budget_notification_email = "you@example.com"

# OPTIONAL (defaults shown). IAM Identity Center must be enabled in the org first,
# or set this false to skip the persona layer.
# enable_identity_center = true

# --- Reduced-footprint toggles (canonical design leaves ALL true) -------------
# Set a flag false only when the target org cannot support that piece:
#   full_account_set            : false = deploy only security/log-archive/sandbox
#                                 (use when the org is at its account-count limit)
#   enable_securityhub          : false = Security Hub already enabled elsewhere
#   enable_cost_anomaly_monitor : false = a SERVICE anomaly monitor already exists
#   enable_tag_policy           : false = TAG_POLICY type/doc not ready
# full_account_set            = true
# enable_securityhub          = true
# enable_cost_anomaly_monitor = true
# enable_tag_policy           = true

# --- Other optional overrides (defaults shown) --------------------------------
# region                 = "us-east-1"
# allowed_regions        = ["us-east-1"]
# monthly_budget_limit   = "20"
# cost_anomaly_threshold = "10"
