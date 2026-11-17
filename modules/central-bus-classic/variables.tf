variable "name" {
  description = "Name of the event bus. Also the prefix of the delivery role and the dead-letter queue."
  type        = string

  validation {
    condition     = can(regex("^[A-Za-z0-9._-]{1,40}$", var.name)) && var.name != "default"
    error_message = "name must be 1 to 40 letters, digits, dots, hyphens or underscores, and not \"default\"."
  }
}

variable "description" {
  description = "Description of the event bus."
  type        = string
  default     = "Organization event bus (Classic) with hierarchy-based access control"
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
  description = "Hierarchy level names, top to bottom. With tag_key_prefix, each name is an IAM principal tag key. The values, joined with separator, form the event source."
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
  description = "Prefix put before each level name to form the IAM tag key."
  type        = string
  default     = ""

  validation {
    condition     = can(regex("^[A-Za-z0-9_.-]*$", var.tag_key_prefix))
    error_message = "tag_key_prefix may contain only letters, digits, dots, hyphens and underscores."
  }
}

variable "separator" {
  description = "Character that joins the hierarchy values into the event source. Hierarchy values must not contain it."
  type        = string
  default     = "."

  validation {
    condition     = contains([".", "/", ":"], var.separator)
    error_message = "separator must be one of . / :"
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

variable "subscriptions" {
  description = <<-EOT
    Subscriptions, declared and reviewed here because a Classic bus keeps
    every rule in the bus account. Each entry creates one rule on the bus and
    one cross-account SQS target. The map key is the rule name.

    owner names whose events to deliver, as a prefix of the hierarchy: all
    levels name one service, fewer levels name everything below that point.

    consumer is the full hierarchy path of the receiving service. The target
    queue must be in one of the accounts of the consumer's top-level unit.

    target_arn is the consumer's SQS queue (output queue_arns of
    spoke-connection-classic).
  EOT
  type = map(object({
    owner      = map(string)
    consumer   = map(string)
    target_arn = string
  }))
  default = {}

  validation {
    condition     = alltrue([for k in keys(var.subscriptions) : can(regex("^[A-Za-z0-9._-]{1,64}$", k))])
    error_message = "Subscription keys are rule names: 1 to 64 letters, digits, dots, hyphens or underscores."
  }

  validation {
    condition = alltrue([
      for s in values(var.subscriptions) :
      length(s.owner) >= 1 && length(s.owner) <= length(var.hierarchy) &&
      toset(keys(s.owner)) == toset(slice(var.hierarchy, 0, min(length(s.owner), length(var.hierarchy))))
    ])
    error_message = "Each owner must name a prefix of the hierarchy, starting at the top level with no gaps."
  }

  validation {
    condition     = alltrue([for s in values(var.subscriptions) : toset(keys(s.consumer)) == toset(var.hierarchy)])
    error_message = "Each consumer must have exactly one value for each hierarchy level."
  }

  validation {
    condition = alltrue(flatten([
      for s in values(var.subscriptions) : [
        for v in concat(values(s.owner), values(s.consumer)) : can(regex("^[A-Za-z0-9_-]+$", v))
      ]
    ]))
    error_message = "Hierarchy values may contain only letters, digits, hyphens and underscores."
  }

  validation {
    condition     = alltrue([for s in values(var.subscriptions) : can(regex("^arn:[a-z-]+:sqs:[a-z0-9-]+:[0-9]{12}:[A-Za-z0-9_-]+$", s.target_arn))])
    error_message = "target_arn must be the ARN of a standard SQS queue."
  }
}

variable "exempt_principal_arns" {
  description = "Principal ARN patterns that may publish any source and are exempt from the Deny guardrails, for example roles that forward AWS service events into the bus. Matched with ArnLike on aws:PrincipalArn."
  type        = list(string)
  default     = []
}

variable "kms_key_arn" {
  description = "Customer managed KMS key for the bus. Null uses the AWS owned key."
  type        = string
  default     = null
}

variable "permissions_boundary" {
  description = "Permissions boundary ARN for the delivery role."
  type        = string
  default     = null
}

variable "policy_size_limit" {
  description = "Size quota of the bus policy in characters."
  type        = number
  default     = 10240
}

variable "rule_limit" {
  description = "Rules-per-bus quota. Raise it only after the Service Quotas increase is granted."
  type        = number
  default     = 300
}

variable "tags" {
  description = "Tags for every resource."
  type        = map(string)
  default     = {}
}
