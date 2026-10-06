output "management_instance" {
  description = "What test-compute.sh asserts against"
  value = var.enable_management_instance ? {
    id         = aws_instance.management[0].id
    name       = "prod-${local.name}"
    ami_id     = aws_instance.management[0].ami
    kms_key_id = local.workload.ebs_kms_key_arn
    subnet_id  = aws_instance.management[0].subnet_id
  } : null
}
