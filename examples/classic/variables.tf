variable "region" {
  description = "Region of the bus and of both workloads."
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

variable "payments_profile" {
  description = "AWS CLI profile for the payments account."
  type        = string
}

variable "payments_account_id" {
  description = "Account ID owned by the payments platform."
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

variable "logistics_profile" {
  description = "AWS CLI profile for the logistics account."
  type        = string
}

variable "logistics_account_id" {
  description = "Account ID owned by the logistics platform."
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
