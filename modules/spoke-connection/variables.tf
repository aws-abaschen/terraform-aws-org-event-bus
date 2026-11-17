variable "name" {
  description = "Short name of the service. Used as prefix for the role, queues and subscribers."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9][A-Za-z0-9_-]{0,40}$", var.name))
    error_message = "name must be 1 to 41 letters, digits, hyphens or underscores, starting with a letter or digit."
  }
}

variable "bus_arn" {
  description = "ARN of the central event bus (output bus_arn of central-bus)."
  type        = string

  validation {
    condition     = can(regex(":event-busv2/", var.bus_arn))
    error_message = "bus_arn must be the ARN of a Custom Event Bus (event-busv2)."
  }
}

variable "organization_id" {
  description = "AWS Organizations ID (o-...). Used in the endpoint policy."
  type        = string
}

variable "hierarchy" {
  description = "Hierarchy level names, top to bottom. Must equal the central-bus value."
  type        = list(string)
  default     = ["platform", "solution", "product", "service"]
}

variable "tag_key_prefix" {
  description = "Prefix of the IAM tag keys. Must equal the central-bus value."
  type        = string
  default     = ""
}

variable "path" {
  description = "Where this service sits in the hierarchy: one value per level."
  type        = map(string)

  validation {
    condition     = toset(keys(var.path)) == toset(var.hierarchy)
    error_message = "path must have exactly one value for each hierarchy level."
  }

  validation {
    condition     = alltrue([for v in values(var.path) : !strcontains(v, var.visibility.separator)])
    error_message = "No path value may contain the visibility separator."
  }
}

variable "visibility" {
  description = "Visibility settings of the bus (output visibility of central-bus)."
  type = object({
    key          = string
    separator    = string
    public_value = optional(string)
  })
  default = {
    key          = "visibility"
    separator    = "."
    public_value = "public"
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
  description = "Attach a policy to the EventBridge endpoint limiting it to the central bus and to organization principals. Set false if the eventsv2 endpoint service turns out not to support endpoint policies."
  type        = bool
  default     = true
}

variable "endpoint_allowed_actions" {
  description = "Actions allowed through the EventBridge endpoint."
  type        = list(string)
  default     = ["events:PutRawEvents", "events:DescribeEventBus"]
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
  description = "Permissions boundary ARN for the roles this module creates."
  type        = string
  default     = null
}

variable "publish" {
  description = "Allow the workload role to publish to the bus."
  type        = bool
  default     = true
}

# --- Subscriptions -----------------------------------------------------------

variable "subscriptions" {
  description = <<-EOT
    Subscriptions of this service. Each creates a subscriber on the central
    bus, an SQS queue and a dead-letter queue in this account.

    visibility lists audiences to receive events for: values of the
    producers' visibility metadata. Each must be this service's path cut at
    some level (payments, payments.cards, ...) or the public value; output
    visibility_audiences lists them. Any producer that set one of them is
    received, unless owner narrows it down.

    owner names whose events to receive, as a prefix of the hierarchy. Without
    visibility, omit it to receive this service's own events; another owner
    then needs a grant in the bus policy.

    transformer_type selects what the queue receives: WITH_METADATA (payload,
    metadata and system metadata) or RAW (payload only).
  EOT
  type = map(object({
    owner                      = optional(map(string))
    visibility                 = optional(list(string))
    transformer_type           = optional(string, "WITH_METADATA")
    visibility_timeout_seconds = optional(number, 30)
    message_retention_seconds  = optional(number, 345600)
  }))
  default = {}

  validation {
    condition = alltrue([
      for s in values(var.subscriptions) : s.owner == null ? true : (
        length(s.owner) >= 1 && length(s.owner) <= length(var.hierarchy) &&
        toset(keys(s.owner)) == toset(slice(var.hierarchy, 0, min(length(s.owner), length(var.hierarchy))))
      )
    ])
    error_message = "owner must name a prefix of the hierarchy, starting at the top level with no gaps."
  }

  validation {
    condition = alltrue(flatten([
      for s in values(var.subscriptions) : s.visibility == null ? [true] : concat(
        [length(s.visibility) > 0],
        [for v in s.visibility : contains(concat(
          [for d in range(1, length(var.hierarchy) + 1) : join(var.visibility.separator, [for l in slice(var.hierarchy, 0, d) : var.path[l]])],
          var.visibility.public_value == null ? [] : [var.visibility.public_value],
        ), v)]
      )
    ]))
    error_message = "visibility must list audiences this service belongs to: its path cut at some level, or the public value."
  }

  validation {
    condition     = alltrue([for s in values(var.subscriptions) : contains(["WITH_METADATA", "RAW"], s.transformer_type)])
    error_message = "transformer_type must be WITH_METADATA or RAW."
  }
}

variable "tags" {
  description = "Tags for every resource. Hierarchy tags on the workload role take precedence."
  type        = map(string)
  default     = {}
}
