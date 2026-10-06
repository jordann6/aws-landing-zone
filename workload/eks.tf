# EKS as the paved-road cluster. Three controls from the design are load-bearing:
# a private API endpoint (no public control plane), KMS envelope encryption of
# Kubernetes secrets in etcd, and an OIDC provider for IRSA so pods get scoped IAM
# roles instead of node credentials or static keys.

resource "aws_kms_key" "eks" {
  count = var.enable_eks ? 1 : 0
  #checkov:skip=CKV2_AWS_64:Default key policy (account-root) is sufficient for same-account EKS envelope encryption.
  description             = "EKS secret envelope encryption (etcd)"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  tags                    = { Name = "prod-eks-cmk" }
}

resource "aws_kms_alias" "eks" {
  count         = var.enable_eks ? 1 : 0
  name          = "alias/prod-eks"
  target_key_id = aws_kms_key.eks[0].key_id
}

# --- cluster IAM role ---
data "aws_iam_policy_document" "eks_assume" {
  count = var.enable_eks ? 1 : 0
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_cluster" {
  count              = var.enable_eks ? 1 : 0
  name               = "prod-eks-cluster"
  assume_role_policy = data.aws_iam_policy_document.eks_assume[0].json
}

resource "aws_iam_role_policy_attachment" "eks_cluster" {
  count      = var.enable_eks ? 1 : 0
  role       = aws_iam_role.eks_cluster[0].name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_security_group" "eks_cluster" {
  #checkov:skip=CKV2_AWS_5:Attached to the cluster in aws_eks_cluster.prod vpc_config; checkov cannot follow the count index.
  count       = var.enable_eks ? 1 : 0
  name        = "prod-eks-cluster"
  description = "EKS control plane"
  vpc_id      = aws_vpc.prod.id

  egress {
    description = "HTTPS to nodes and endpoints"
    from_port   = 443
    to_port     = 443
    protocol    = "tcp"
    cidr_blocks = [var.prod_cidr]
  }

  tags = { Name = "prod-eks-cluster" }
}

resource "aws_eks_cluster" "prod" {
  count    = var.enable_eks ? 1 : 0
  name     = "prod"
  role_arn = aws_iam_role.eks_cluster[0].arn
  version  = var.eks_version

  vpc_config {
    subnet_ids              = local.node_subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = false # no public control plane
    security_group_ids      = [aws_security_group.eks_cluster[0].id]
  }

  # Envelope-encrypt Kubernetes secrets in etcd with the CMK.
  encryption_config {
    provider {
      key_arn = aws_kms_key.eks[0].arn
    }
    resources = ["secrets"]
  }

  # Access entries (API) alongside the aws-auth ConfigMap. The incident
  # responder's remediation role gets a namespace-scoped entry, and EKS creates
  # node group entries itself, so nothing is written to aws-auth by hand.
  access_config {
    authentication_mode                         = "API_AND_CONFIG_MAP"
    bootstrap_cluster_creator_admin_permissions = true
  }

  # Full control-plane audit logging.
  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  depends_on = [aws_iam_role_policy_attachment.eks_cluster]
}

# --- IRSA: OIDC provider trust for pod-scoped IAM roles ---
data "tls_certificate" "eks" {
  count = var.enable_eks ? 1 : 0
  url   = aws_eks_cluster.prod[0].identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  count           = var.enable_eks ? 1 : 0
  url             = aws_eks_cluster.prod[0].identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks[0].certificates[0].sha1_fingerprint]
}

# --- managed node group ---
data "aws_iam_policy_document" "node_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["ec2.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_node" {
  count              = var.enable_eks ? 1 : 0
  name               = "prod-eks-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = var.enable_eks ? toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ]) : toset([])
  role       = aws_iam_role.eks_node[0].name
  policy_arn = each.value
}

# Nodes stay on the EKS-optimized AL2023 image, which EKS patches and versions
# with the control plane; the golden AMI is for standalone instances only. The
# launch template only hardens how that image boots: IMDSv2 at hop limit 1 (pods
# use IRSA, so they cannot borrow the node role) and a KMS-encrypted gp3 root.
resource "aws_launch_template" "eks_node" {
  count       = var.enable_eks ? 1 : 0
  name_prefix = "prod-eks-node-"
  description = "Hardened boot settings for the managed node group"

  metadata_options {
    http_endpoint               = "enabled"
    http_tokens                 = "required"
    http_put_response_hop_limit = 1
    instance_metadata_tags      = "disabled"
  }

  block_device_mappings {
    device_name = "/dev/xvda"
    ebs {
      volume_size           = 20
      volume_type           = "gp3"
      encrypted             = true
      kms_key_id            = aws_kms_key.ebs.arn
      delete_on_termination = true
    }
  }

  tag_specifications {
    resource_type = "instance"
    tags          = { Name = "prod-eks-node" }
  }
}

resource "aws_eks_node_group" "prod" {
  count           = var.enable_eks ? 1 : 0
  cluster_name    = aws_eks_cluster.prod[0].name
  node_group_name = "default"
  node_role_arn   = aws_iam_role.eks_node[0].arn
  subnet_ids      = local.node_subnet_ids
  instance_types  = [var.eks_node_instance_type]
  ami_type        = "AL2023_x86_64_STANDARD"

  launch_template {
    id      = aws_launch_template.eks_node[0].id
    version = aws_launch_template.eks_node[0].latest_version
  }

  scaling_config {
    desired_size = 2
    min_size     = 1
    max_size     = 3
  }

  update_config {
    max_unavailable = 1
  }

  depends_on = [aws_iam_role_policy_attachment.node]
}
