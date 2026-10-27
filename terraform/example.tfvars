# Copy to terraform.tfvars (gitignored) and fill in. terraform.tfvars holds the
# environment-specific and sensitive values; this template is safe to commit.

# REQUIRED. Where budget and cost-anomaly alerts are delivered.
budget_notification_email = "you@example.com"

# OPTIONAL (defaults shown). IAM Identity Center must be enabled in the org first,
# or set this false to skip the persona layer.
# enable_identity_center = true

# OPTIONAL. The operator's own Identity Center user, added to the admin group, so
# the workstation can sign in with short-lived sessions instead of an access key.
# operator_user = {
#   user_name   = "you"
#   given_name  = "Given"
#   family_name = "Family"
#   email       = "you@example.com"
# }

# --- Reduced-footprint toggles (canonical design leaves ALL true) -------------
# Set a flag false only when the target org cannot support that piece. The
# account set and tag policy toggles are in accounts/example.tfvars.
#   enable_securityhub          : false = Security Hub already enabled elsewhere
#   enable_cost_anomaly_monitor : false = a SERVICE anomaly monitor already exists
# enable_securityhub          = true
# enable_cost_anomaly_monitor = true

# --- Other optional overrides (defaults shown) --------------------------------
# region                 = "us-east-1"
# monthly_budget_limit   = "20"
# cost_anomaly_threshold = "10"
