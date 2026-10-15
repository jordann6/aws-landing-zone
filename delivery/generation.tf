# Identifies this instance of the delivery layer. Published in the contract and tagged
# on the deploy repository; consumers reject a contract whose generation differs from
# the live tag (ADR-0005), which catches contracts left behind by a destroy.
resource "random_id" "generation" {
  byte_length = 8
}
