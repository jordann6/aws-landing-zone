# EKS as the paved-road cluster. Three controls from the design are load-bearing:
# a private API endpoint (no public control plane), KMS envelope encryption of
# Kubernetes secrets in etcd, and an OIDC provider for IRSA so pods get scoped IAM
# roles instead of node credentials or static keys.

resource "aws_kms_key" "eks" {
  #checkov:skip=CKV2_AWS_64:Default key policy (account-root) is sufficient for same-account EKS envelope encryption.
  description             = "EKS secret envelope encryption (etcd)"
  enable_key_rotation     = true
  deletion_window_in_days = 7
  tags                    = { Name = "prod-eks-cmk" }
}

resource "aws_kms_alias" "eks" {
  name          = "alias/prod-eks"
  target_key_id = aws_kms_key.eks.key_id
}

# --- cluster IAM role ---
data "aws_iam_policy_document" "eks_assume" {
  statement {
    actions = ["sts:AssumeRole"]
    principals {
      type        = "Service"
      identifiers = ["eks.amazonaws.com"]
    }
  }
}

resource "aws_iam_role" "eks_cluster" {
  name               = "prod-eks-cluster"
  assume_role_policy = data.aws_iam_policy_document.eks_assume.json
}

resource "aws_iam_role_policy_attachment" "eks_cluster" {
  role       = aws_iam_role.eks_cluster.name
  policy_arn = "arn:aws:iam::aws:policy/AmazonEKSClusterPolicy"
}

resource "aws_security_group" "eks_cluster" {
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
  name     = "prod"
  role_arn = aws_iam_role.eks_cluster.arn
  version  = var.eks_version

  vpc_config {
    subnet_ids              = local.node_subnet_ids
    endpoint_private_access = true
    endpoint_public_access  = false # no public control plane
    security_group_ids      = [aws_security_group.eks_cluster.id]
  }

  # Envelope-encrypt Kubernetes secrets in etcd with the CMK.
  encryption_config {
    provider {
      key_arn = aws_kms_key.eks.arn
    }
    resources = ["secrets"]
  }

  # Full control-plane audit logging.
  enabled_cluster_log_types = ["api", "audit", "authenticator", "controllerManager", "scheduler"]

  depends_on = [aws_iam_role_policy_attachment.eks_cluster]
}

# --- IRSA: OIDC provider trust for pod-scoped IAM roles ---
data "tls_certificate" "eks" {
  url = aws_eks_cluster.prod.identity[0].oidc[0].issuer
}

resource "aws_iam_openid_connect_provider" "eks" {
  url             = aws_eks_cluster.prod.identity[0].oidc[0].issuer
  client_id_list  = ["sts.amazonaws.com"]
  thumbprint_list = [data.tls_certificate.eks.certificates[0].sha1_fingerprint]
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
  name               = "prod-eks-node"
  assume_role_policy = data.aws_iam_policy_document.node_assume.json
}

resource "aws_iam_role_policy_attachment" "node" {
  for_each = toset([
    "arn:aws:iam::aws:policy/AmazonEKSWorkerNodePolicy",
    "arn:aws:iam::aws:policy/AmazonEKS_CNI_Policy",
    "arn:aws:iam::aws:policy/AmazonEC2ContainerRegistryReadOnly",
    "arn:aws:iam::aws:policy/AmazonSSMManagedInstanceCore",
  ])
  role       = aws_iam_role.eks_node.name
  policy_arn = each.value
}

resource "aws_eks_node_group" "prod" {
  cluster_name    = aws_eks_cluster.prod.name
  node_group_name = "default"
  node_role_arn   = aws_iam_role.eks_node.arn
  subnet_ids      = local.node_subnet_ids
  instance_types  = [var.eks_node_instance_type]
  ami_type        = "AL2023_x86_64_STANDARD"

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
