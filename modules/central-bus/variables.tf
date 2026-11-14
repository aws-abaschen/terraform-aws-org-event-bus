variable "name" {
  description = "Name of the event bus."
  type        = string
}

variable "description" {
  description = "Description of the event bus."
  type        = string
  default     = "Organization event bus with hierarchy-based access control"
}

variable "organization_id" {
  description = "AWS Organizations ID (o-...). Every Allow statement in the bus policy is limited to principals of this organization."
  type        = string

  validation {
    condition     = can(regex("^o-[a-z0-9]{10,32}$", var.organization_id))
    error_message = "organization_id must look like o-a1b2c3d4e5."
  }
}

variable "hierarchy" {
  description = "Hierarchy level names, top to bottom. Each name is an event metadata key and, with tag_key_prefix, an IAM principal tag key."
  type        = list(string)
  default     = ["platform", "solution", "product", "service"]

  validation {
    condition     = length(var.hierarchy) >= 1 && length(distinct(var.hierarchy)) == length(var.hierarchy)
    error_message = "hierarchy needs at least one level and no duplicates."
  }

  validation {
    condition     = alltrue([for l in var.hierarchy : can(regex("^[A-Za-z][A-Za-z0-9_-]*$", l))])
    error_message = "Level names must start with a letter and contain only letters, digits, hyphens and underscores."
  }
}

variable "tag_key_prefix" {
  description = "Prefix put before each level name to form the IAM tag key. The event metadata keys are never prefixed."
  type        = string
  default     = ""

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]*$", var.tag_key_prefix))
    error_message = "tag_key_prefix may contain only letters, digits, dots, hyphens and underscores."
  }
}

variable "platforms" {
  description = "Top-level units and the AWS accounts each one owns. A principal whose top-level tag names a unit is denied unless it is in one of that unit's accounts; a principal whose top-level tag names no registered unit is denied."
  type = map(object({
    account_ids = list(string)
  }))

  validation {
    condition     = alltrue(flatten([for p in values(var.platforms) : [for a in p.account_ids : can(regex("^[0-9]{12}$", a))]]))
    error_message = "account_ids must be 12-digit AWS account IDs."
  }
}

variable "own_read_scope" {
  description = "Level down to which a principal may subscribe without a grant. The default (null) is the last level: a service reads only its own events. Set it to a higher level, for example product, to let every service read all events of its own product."
  type        = string
  default     = null

  validation {
    condition     = var.own_read_scope == null || contains(var.hierarchy, coalesce(var.own_read_scope, "-"))
    error_message = "own_read_scope must be one of the hierarchy levels."
  }
}

variable "grants" {
  description = <<-EOT
    Allow-list. Each grant lets the consumer subscribe to the owner's events.
    owner and consumer are maps of level name to value and must cover a
    prefix of the hierarchy: all levels names one service, fewer levels name
    everything below that point (for example a whole product).
  EOT
  type = list(object({
    owner    = map(string)
    consumer = map(string)
  }))
  default = []

  validation {
    condition = alltrue(flatten([
      for g in var.grants : [
        for path in [g.owner, g.consumer] :
        length(path) >= 1 && length(path) <= length(var.hierarchy) &&
        toset(keys(path)) == toset(slice(var.hierarchy, 0, min(length(path), length(var.hierarchy))))
      ]
    ]))
    error_message = "Each owner and consumer must name a prefix of the hierarchy, starting at the top level with no gaps."
  }
}

variable "exempt_principal_arns" {
  description = "Principal ARN patterns exempt from the Deny guardrails, for example platform operators or roles that forward AWS service events into the bus. Matched with ArnNotLike on aws:PrincipalArn."
  type        = list(string)
  default     = []
}

variable "allow_put_events" {
  description = "Allow the PutEvents envelope API. It carries no metadata, so events published with it bypass the hierarchy. Keep false unless every such publisher is in exempt_principal_arns."
  type        = bool
  default     = false
}

variable "share_with" {
  description = "Organization, OU or account ARNs/IDs to share the bus with through AWS RAM (publish only). Optional: the bus policy already grants the organization access. A RAM share makes the bus appear in ListEventBuses in the consumer accounts."
  type        = list(string)
  default     = []
}

variable "retention_days" {
  description = "How long the bus retains events, 1 to 365 days."
  type        = number
  default     = 7

  validation {
    condition     = var.retention_days >= 1 && var.retention_days <= 365
    error_message = "retention_days must be between 1 and 365."
  }
}

variable "kms_key_arn" {
  description = "Customer managed KMS key for the bus. Null uses the AWS owned key."
  type        = string
  default     = null
}

variable "policy_size_limit" {
  description = "Size quota of the bus default policy in bytes. Raise it only after the Service Quotas increase is granted."
  type        = number
  default     = 20480
}

variable "tags" {
  description = "Tags for the bus and the RAM share."
  type        = map(string)
  default     = {}
}
