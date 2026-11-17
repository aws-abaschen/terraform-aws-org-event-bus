variable "name" {
  description = "Short name of the service. Used as prefix for the role and queues."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9_-]{0,40}$", var.name))
    error_message = "name must be 1 to 41 letters, digits, hyphens or underscores, starting with a letter or digit."
  }
}

variable "bus_arn" {
  description = "ARN of the central event bus (output bus_arn of central-bus-classic)."
  type        = string

  validation {
    condition     = can(regex(":event-bus/", var.bus_arn))
    error_message = "bus_arn must be the ARN of a Custom Event Bus - Classic (event-bus)."
  }
}

variable "organization_id" {
  description = "AWS Organizations ID (o-...). Used in the endpoint policy."
  type        = string
}

variable "hierarchy" {
  description = "Hierarchy level names, top to bottom. Must equal the central-bus-classic value."
  type        = list(string)
  default     = ["platform", "solution", "product", "service"]
}

variable "tag_key_prefix" {
  description = "Prefix of the IAM tag keys. Must equal the central-bus-classic value."
  type        = string
  default     = ""
}

variable "separator" {
  description = "Separator of the event source. Must equal the central-bus-classic value."
  type        = string
  default     = "."
}

variable "path" {
  description = "Where this service sits in the hierarchy: one value per level."
  type        = map(string)

  validation {
    condition     = toset(keys(var.path)) == toset(var.hierarchy)
    error_message = "path must have exactly one value for each hierarchy level."
  }

  validation {
    condition     = alltrue([for v in values(var.path) : can(regex("^[A-Za-z0-9_-]+$", v))])
    error_message = "path values may contain only letters, digits, hyphens and underscores."
  }
}

# --- Network -----------------------------------------------------------------

variable "create_endpoints" {
  description = "Create the interface endpoints in the VPC. Set false for the second and later services that share a VPC."
  type        = bool
  default     = true
}

variable "vpc_id" {
  description = "VPC for the endpoints. Required when create_endpoints is true."
  type        = string
  default     = null
}

variable "subnet_ids" {
  description = "Private subnets for the endpoints, one per Availability Zone. Required when create_endpoints is true."
  type        = list(string)
  default     = []
}

variable "endpoint_ingress_cidr_blocks" {
  description = "CIDR blocks allowed to reach the endpoints on 443. Null uses the VPC's primary CIDR."
  type        = list(string)
  default     = null
}

variable "create_sqs_endpoint" {
  description = "Also create the SQS interface endpoint, so the workload can read its queues without internet access."
  type        = bool
  default     = true
}

variable "enable_endpoint_policy" {
  description = "Attach a policy to the EventBridge endpoint limiting it to the central bus and to organization principals."
  type        = bool
  default     = true
}

variable "endpoint_allowed_actions" {
  description = "Actions allowed through the EventBridge endpoint."
  type        = list(string)
  default     = ["events:PutEvents", "events:DescribeEventBus"]
}

# --- Workload role -----------------------------------------------------------

variable "create_role" {
  description = "Create the workload role, tagged with the hierarchy path."
  type        = bool
  default     = true
}

variable "assume_role_policy" {
  description = "Trust policy JSON of the workload role. Required when create_role is true. Do not allow sts:TagSession: session tags override role tags."
  type        = string
  default     = null
}

variable "permissions_boundary" {
  description = "Permissions boundary ARN for the workload role."
  type        = string
  default     = null
}

variable "publish" {
  description = "Allow the workload role to publish to the bus."
  type        = bool
  default     = true
}

# --- Queues ------------------------------------------------------------------

variable "delivery_role_arn" {
  description = "Delivery role of the central bus (output delivery_role_arn of central-bus-classic). Each queue accepts messages from it. Required when queues is not empty."
  type        = string
  default     = null
}

variable "queues" {
  description = <<-EOT
    Queues that receive events from the central bus. Each entry creates an
    SQS queue in this account whose policy accepts the central delivery role.

    A queue receives nothing until the platform team declares a subscription
    for it in central-bus-classic, with this queue's ARN as target_arn. What
    the queue receives is decided there, not here.
  EOT
  type = map(object({
    visibility_timeout_seconds = optional(number, 30)
    message_retention_seconds  = optional(number, 345600)
  }))
  default = {}
}

variable "kms_key_arn" {
  description = "Customer managed KMS key for the queues. Null uses the key this module creates. A key passed in must allow delivery_role_arn kms:GenerateDataKey and kms:Decrypt in its key policy, because the role is in another account."
  type        = string
  default     = null
}

variable "create_kms_key" {
  description = "Create a customer managed key with rotation for the queues when kms_key_arn is null. Set false only together with kms_key_arn."
  type        = bool
  default     = true
}

variable "tags" {
  description = "Tags for every resource. Hierarchy tags on the workload role take precedence."
  type        = map(string)
  default     = {}
}
