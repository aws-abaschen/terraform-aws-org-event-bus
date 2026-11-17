variable "region" {
  description = "Region of the bus and of both workloads. Must be one where the Custom Event Bus is available."
  type        = string
  default     = "eu-west-1"
}

variable "organization_id" {
  description = "AWS Organizations ID (o-...)."
  type        = string
}

variable "platform_profile" {
  description = "AWS CLI profile for the event platform account."
  type        = string
}

variable "organization_profile" {
  description = "AWS CLI profile able to read AWS Organizations: the management account or a delegated administrator."
  type        = string
}

variable "payments_profile" {
  description = "AWS CLI profile able to assume the authorizer deployment role."
  type        = string
}

variable "payments_vpc_id" {
  description = "Workload VPC in the payments account."
  type        = string
}

variable "payments_subnet_ids" {
  description = "Private subnets in the payments VPC."
  type        = list(string)
}

variable "authorizer_deployer_role_arn" {
  description = "Deployment role tagged with the authorizer's hierarchy path (examples/deployer-role)."
  type        = string
}

variable "logistics_profile" {
  description = "AWS CLI profile able to assume the tracker deployment role."
  type        = string
}

variable "logistics_vpc_id" {
  description = "Workload VPC in the logistics account."
  type        = string
}

variable "logistics_subnet_ids" {
  description = "Private subnets in the logistics VPC."
  type        = list(string)
}

variable "tracker_deployer_role_arn" {
  description = "Deployment role tagged with the tracker's hierarchy path (examples/deployer-role)."
  type        = string
}
