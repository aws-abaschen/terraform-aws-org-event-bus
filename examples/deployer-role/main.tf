# One deployment role per service, tagged with the service's hierarchy path.
# Apply as the account vending or provisioning role (the principal exempted
# in the guardrail SCP). The service's pipeline then assumes this role to
# apply spoke-connection: the bus policy authorizes CreateSubscriber against
# these tags, and the SCP lets this role create only identically tagged roles.

terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
}

variable "name" {
  description = "Role name."
  type        = string
}

variable "path" {
  description = "Hierarchy path of the service: one value per level."
  type        = map(string)
}

variable "tag_key_prefix" {
  description = "Prefix of the IAM tag keys (central-bus tag_key_prefix)."
  type        = string
  default     = ""
}

variable "trusted_principal_arns" {
  description = "Principals allowed to assume the role, for example the pipeline's OIDC role."
  type        = list(string)
}

variable "managed_policy_arns" {
  description = "Permissions of the deployment role. The default is deliberately broad for a first run; narrow it to IAM, SQS, VPC endpoint and events actions for production."
  type        = list(string)
  default     = ["arn:aws:iam::aws:policy/AdministratorAccess"]
}

resource "aws_iam_role" "this" {
  name = var.name
  tags = { for l, v in var.path : "${var.tag_key_prefix}${l}" => v }

  # sts:AssumeRole only. Never add sts:TagSession here.
  assume_role_policy = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { AWS = var.trusted_principal_arns }
      Action    = "sts:AssumeRole"
    }]
  })
}

resource "aws_iam_role_policy_attachment" "this" {
  for_each = toset(var.managed_policy_arns)

  role       = aws_iam_role.this.name
  policy_arn = each.value
}

output "role_arn" {
  description = "ARN to put in the aws and awscc provider assume_role blocks of the service's stack."
  value       = aws_iam_role.this.arn
}
