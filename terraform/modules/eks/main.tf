module "eks" {
  source  = "terraform-aws-modules/eks/aws"
  version = "20.0.0"

  cluster_name    = var.cluster_name
  cluster_version = var.cluster_version
  vpc_id          = var.vpc_id
  subnet_ids      = var.private_subnets

  cluster_endpoint_public_access  = true
  cluster_endpoint_private_access = true

  eks_managed_node_groups = {
    general = {
      min_size       = var.env == "prod" ? 3 : 1
      max_size       = var.env == "prod" ? 10 : 3
      desired_size   = 2
      instance_types = [var.node_instance_type]
      capacity_type  = var.env == "prod" ? "ON_DEMAND" : "SPOT"
      labels         = { role = "general" }
    }
  }

  cluster_addons = {
    coredns            = { most_recent = true }
    kube-proxy         = { most_recent = true }
    vpc-cni            = { most_recent = true }
    aws-ebs-csi-driver = { most_recent = true }
  }

  enable_cluster_creator_admin_permissions = true
}
