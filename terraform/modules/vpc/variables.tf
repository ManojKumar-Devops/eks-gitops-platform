variable "project"         { type = string }
variable "env"             { type = string }
variable "vpc_cidr"        { type = string }
variable "private_subnets" { type = list(string) }
variable "public_subnets"  { type = list(string) }
variable "cluster_name"    { type = string }
