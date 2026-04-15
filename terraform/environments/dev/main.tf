module "vpc" {
  source = "../../modules/vpc"

  project         = "eks-platform"
  env             = "dev"
  cluster_name    = "eks-platform-dev"
  vpc_cidr        = "10.0.0.0/16"
  private_subnets = ["10.0.1.0/24", "10.0.2.0/24", "10.0.3.0/24"]
  public_subnets  = ["10.0.101.0/24", "10.0.102.0/24", "10.0.103.0/24"]
}

module "eks" {
  source = "../../modules/eks"

  cluster_name       = "eks-platform-dev"
  cluster_version    = "1.32"
  vpc_id             = module.vpc.vpc_id
  private_subnets    = module.vpc.private_subnets
  env                = "dev"
  node_instance_type = "t3.medium"
}

output "vpc_id" {
  value = module.vpc.vpc_id
}

output "cluster_name" {
  value = module.eks.cluster_name
}

output "cluster_endpoint" {
  value = module.eks.cluster_endpoint
}
