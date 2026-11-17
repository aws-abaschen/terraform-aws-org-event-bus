variable "tag_key" {
  description = "Account tag (AWS Organizations) whose value names the account's top-level unit, for example platform. Accounts without it are left out."
  type        = string
  default     = "platform"
}

variable "parent_id" {
  description = "Root or OU (r-... or ou-...) whose accounts, at any depth, are read. Null reads every account of the organization."
  type        = string
  default     = null

  validation {
    condition     = var.parent_id == null || can(regex("^(r-[a-z0-9]{4,32}|ou-[a-z0-9]{4,32}-[a-z0-9]{8,32})$", coalesce(var.parent_id, "-")))
    error_message = "parent_id must be a root ID (r-...) or an OU ID (ou-...)."
  }
}

variable "allowed_values" {
  description = "If not empty, the only tag values accepted. An account tagged with another value fails the plan instead of becoming a new unit."
  type        = list(string)
  default     = []
}
