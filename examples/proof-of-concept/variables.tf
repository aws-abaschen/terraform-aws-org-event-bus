variable "region" {
  description = "Region for the bus and the spoke resources. Must be one where the Custom Event Bus is available."
  type        = string
  default     = "eu-west-1"
}

variable "platform_profile" {
  description = "AWS CLI profile for the account that owns the bus."
  type        = string
}

variable "spoke_profile" {
  description = "AWS CLI profile for the workload account. Must be a different account from the platform account."
  type        = string
}

variable "name_prefix" {
  description = "Prefix for every resource this proof of concept creates."
  type        = string
  default     = "eb-abac-poc"
}

variable "hierarchy" {
  description = "Hierarchy level names, top to bottom. Each is both an event metadata key and an IAM principal tag key."
  type        = list(string)
  default     = ["platform", "solution", "product", "service"]
}

variable "services" {
  description = "Test workloads, each with one value per hierarchy level. The keys owner, granted and stranger are used by run-tests.sh."
  type        = map(map(string))
  default = {
    owner = {
      platform = "payments"
      solution = "cards"
      product  = "issuing"
      service  = "authorizer"
    }
    granted = {
      platform = "payments"
      solution = "cards"
      product  = "disputes"
      service  = "case-manager"
    }
    stranger = {
      platform = "logistics"
      solution = "delivery"
      product  = "tracking"
      service  = "tracker"
    }
  }

  validation {
    condition     = alltrue([for k in ["owner", "granted", "stranger"] : contains(keys(var.services), k)])
    error_message = "services must define owner, granted and stranger."
  }
}
