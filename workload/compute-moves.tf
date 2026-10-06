moved {
  from = aws_kms_key.eks
  to   = aws_kms_key.eks[0]
}

moved {
  from = aws_kms_alias.eks
  to   = aws_kms_alias.eks[0]
}

moved {
  from = aws_iam_role.eks_cluster
  to   = aws_iam_role.eks_cluster[0]
}

moved {
  from = aws_iam_role_policy_attachment.eks_cluster
  to   = aws_iam_role_policy_attachment.eks_cluster[0]
}

moved {
  from = aws_security_group.eks_cluster
  to   = aws_security_group.eks_cluster[0]
}

moved {
  from = aws_eks_cluster.prod
  to   = aws_eks_cluster.prod[0]
}

moved {
  from = aws_iam_openid_connect_provider.eks
  to   = aws_iam_openid_connect_provider.eks[0]
}

moved {
  from = aws_iam_role.eks_node
  to   = aws_iam_role.eks_node[0]
}

moved {
  from = aws_eks_node_group.prod
  to   = aws_eks_node_group.prod[0]
}

moved {
  from = aws_iam_role.cloudwatch_agent
  to   = aws_iam_role.cloudwatch_agent[0]
}

moved {
  from = aws_iam_role_policy_attachment.cloudwatch_agent
  to   = aws_iam_role_policy_attachment.cloudwatch_agent[0]
}

moved {
  from = aws_eks_addon.cloudwatch_observability
  to   = aws_eks_addon.cloudwatch_observability[0]
}

moved {
  from = aws_db_subnet_group.data
  to   = aws_db_subnet_group.data[0]
}

moved {
  from = aws_db_instance.prod
  to   = aws_db_instance.prod[0]
}

moved {
  from = aws_backup_vault.prod
  to   = aws_backup_vault.prod[0]
}

moved {
  from = aws_backup_vault_lock_configuration.prod
  to   = aws_backup_vault_lock_configuration.prod[0]
}

moved {
  from = aws_iam_role.backup
  to   = aws_iam_role.backup[0]
}

moved {
  from = aws_iam_role_policy_attachment.backup
  to   = aws_iam_role_policy_attachment.backup[0]
}

moved {
  from = aws_backup_plan.prod
  to   = aws_backup_plan.prod[0]
}

moved {
  from = aws_backup_selection.prod
  to   = aws_backup_selection.prod[0]
}

moved {
  from = aws_kms_key.data
  to   = aws_kms_key.data[0]
}

moved {
  from = aws_kms_alias.data
  to   = aws_kms_alias.data[0]
}

moved {
  from = aws_iam_role.eso
  to   = aws_iam_role.eso[0]
}

moved {
  from = aws_iam_role_policy.eso
  to   = aws_iam_role_policy.eso[0]
}

moved {
  from = aws_ec2_transit_gateway_route_table_association.prod
  to   = aws_ec2_transit_gateway_route_table_association.prod[0]
}

moved {
  from = aws_ec2_transit_gateway_route_table_propagation.prod
  to   = aws_ec2_transit_gateway_route_table_propagation.prod[0]
}

moved {
  from = aws_ec2_transit_gateway_vpc_attachment.prod
  to   = aws_ec2_transit_gateway_vpc_attachment.prod[0]
}

moved {
  from = aws_ec2_transit_gateway_vpc_attachment_accepter.prod
  to   = aws_ec2_transit_gateway_vpc_attachment_accepter.prod[0]
}

moved {
  from = aws_route.private_default
  to   = aws_route.private_default[0]
}
