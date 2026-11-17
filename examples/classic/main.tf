# The Classic fallback: one platform account and two workload accounts.
#
#   payments account:  authorizer  publishes
#   logistics account: tracker     receives authorizer's events
#
# Use this only where the Custom Event Bus is not available or its access
# model failed the proof of concept. See "Fallback" in the root README.
#
# In a real estate these are three separate stacks owned by three teams.
# They are shown together so the wiring is visible in one place.

terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
  }
}

locals {
  authorizer = { platform = "payments", solution = "cards", product = "issuing", service = "authorizer" }
  tracker    = { platform = "logistics", solution = "delivery", product = "tracking", service = "tracker" }

  # Workloads here run on ECS; use whatever trust your compute needs.
  ecs_trust = jsonencode({
    Version = "2012-10-17"
    Statement = [{
      Effect    = "Allow"
      Principal = { Service = "ecs-tasks.amazonaws.com" }
      Action    = "sts:AssumeRole"
    }]
  })
}

# --- Platform account --------------------------------------------------------

provider "aws" {
  alias   = "platform"
  region  = var.region
  profile = var.platform_profile
}

module "central_bus" {
  source    = "../../modules/central-bus-classic"
  providers = { aws = aws.platform }

  name            = "org"
  organization_id = var.organization_id

  platforms = {
    payments  = { account_ids = [var.payments_account_id] }
    logistics = { account_ids = [var.logistics_account_id] }
  }

  # Every subscription is declared here, because the platform account owns
  # every rule. In a real estate, load these from one file per owner service
  # and make the owning team the required reviewer of its file.
  subscriptions = {
    tracker-authorizer = {
      owner      = local.authorizer
      consumer   = local.tracker
      target_arn = module.tracker.queue_arns["authorizer"]

      target_kms_key_arn = module.tracker.kms_key_arn
    }
  }
}

# --- Payments account: the publisher -----------------------------------------

provider "aws" {
  alias   = "payments"
  region  = var.region
  profile = var.payments_profile
}

module "authorizer" {
  source    = "../../modules/spoke-connection-classic"
  providers = { aws = aws.payments }

  name            = "authorizer"
  bus_arn         = module.central_bus.bus_arn
  organization_id = var.organization_id
  hierarchy       = module.central_bus.hierarchy
  tag_key_prefix  = module.central_bus.tag_key_prefix
  separator       = module.central_bus.separator
  path            = local.authorizer

  vpc_id     = var.payments_vpc_id
  subnet_ids = var.payments_subnet_ids

  # Publishes only, so it needs no SQS endpoint.
  create_sqs_endpoint = false
  assume_role_policy  = local.ecs_trust
}

# --- Logistics account: the consumer -----------------------------------------

provider "aws" {
  alias   = "logistics"
  region  = var.region
  profile = var.logistics_profile
}

module "tracker" {
  source    = "../../modules/spoke-connection-classic"
  providers = { aws = aws.logistics }

  name            = "tracker"
  bus_arn         = module.central_bus.bus_arn
  organization_id = var.organization_id
  hierarchy       = module.central_bus.hierarchy
  tag_key_prefix  = module.central_bus.tag_key_prefix
  separator       = module.central_bus.separator
  path            = local.tracker

  vpc_id     = var.logistics_vpc_id
  subnet_ids = var.logistics_subnet_ids

  assume_role_policy = local.ecs_trust
  publish            = false

  # The queue exists here; what it receives is the subscription above.
  delivery_role_arn = module.central_bus.delivery_role_arn
  queues = {
    authorizer = {}
  }
}
