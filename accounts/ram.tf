# Organizations trusted access alone does not onboard RAM or create its
# service-linked role. This belongs to the persistent account lifecycle.
resource "aws_ram_sharing_with_organization" "this" {
  depends_on = [aws_organizations_organization.org]
  lifecycle {
    prevent_destroy = true
  }
}

output "ram_organization_sharing_enabled" {
  value      = true
  depends_on = [aws_ram_sharing_with_organization.this]
}
