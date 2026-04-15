variable "cluster_name"        { type = string }
variable "cluster_version"     { type = string }
variable "vpc_id"              { type = string }
variable "private_subnets"     { type = list(string) }
variable "env"                 { type = string }
variable "node_instance_type"  { type = string }
