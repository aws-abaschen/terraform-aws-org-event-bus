# One platform account and two workload accounts.
#
#   payments account:  authorizer  publishes, and reads its own events
#   logistics account: tracker     reads the events the authorizer makes
#                                  visible to it
#
# The authorizer decides who reads each event: it puts an audience namespace
# in the visibility metadata key of PutRawEvents, for example
#   visibility = "logistics.delivery.tracking"   (the tracking product)
#   visibility = "public"                        (the whole organization)
# Nothing in the central stack changes when producers or consumers change.
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
    awscc = {
      source  = "hashicorp/awscc"
      version = ">= 1.0"
    }
  }
}

locals {
  hierarchy = ["platform", "solution", "product", "service"]

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

provider "awscc" {
  alias   = "platform"
  region  = var.region
  profile = var.platform_profile
}

# Reads Organizations; the bus account cannot. Use the management account or
# a delegated administrator for AWS Organizations, read-only is enough.
provider "aws" {
  alias   = "organization"
  region  = var.region
  profile = var.organization_profile
}

# Each account carries a `platform` tag in AWS Organizations, set when the
# account is vended. The account vending pipeline re-applies this stack after
# it creates or retags an account; spokes never need to touch it.
module "account_platforms" {
  source    = "../../modules/account-platforms"
  providers = { aws = aws.organization }

  tag_key = local.hierarchy[0]
}

module "central_bus" {
  source = "../../modules/central-bus"
  providers = {
    aws   = aws.platform
    awscc = awscc.platform
  }

  name            = "org"
  organization_id = var.organization_id
  hierarchy       = local.hierarchy
  platforms       = module.account_platforms.platforms
}

# --- Payments account: authorizer --------------------------------------------
# Both providers assume the service's deployment role (examples/deployer-role).

provider "aws" {
  alias   = "authorizer"
  region  = var.region
  profile = var.payments_profile
  assume_role {
    role_arn = var.authorizer_deployer_role_arn
  }
}

provider "awscc" {
  alias   = "authorizer"
  region  = var.region
  profile = var.payments_profile
  assume_role = {
    role_arn = var.authorizer_deployer_role_arn
  }
}

module "authorizer" {
  source = "../../modules/spoke-connection"
  providers = {
    aws   = aws.authorizer
    awscc = awscc.authorizer
  }

  name            = "authorizer"
  bus_arn         = module.central_bus.bus_arn
  organization_id = var.organization_id
  hierarchy       = module.central_bus.hierarchy
  visibility      = module.central_bus.visibility
  path            = local.authorizer

  vpc_id     = var.payments_vpc_id
  subnet_ids = var.payments_subnet_ids

  assume_role_policy = local.ecs_trust

  subscriptions = {
    own = {} # this service's own events
  }
}

# --- Logistics account: tracker ----------------------------------------------

provider "aws" {
  alias   = "tracker"
  region  = var.region
  profile = var.logistics_profile
  assume_role {
    role_arn = var.tracker_deployer_role_arn
  }
}

provider "awscc" {
  alias   = "tracker"
  region  = var.region
  profile = var.logistics_profile
  assume_role = {
    role_arn = var.tracker_deployer_role_arn
  }
}

module "tracker" {
  source = "../../modules/spoke-connection"
  providers = {
    aws   = aws.tracker
    awscc = awscc.tracker
  }

  name            = "tracker"
  bus_arn         = module.central_bus.bus_arn
  organization_id = var.organization_id
  hierarchy       = module.central_bus.hierarchy
  visibility      = module.central_bus.visibility
  path            = local.tracker

  vpc_id     = var.logistics_vpc_id
  subnet_ids = var.logistics_subnet_ids

  assume_role_policy = local.ecs_trust
  publish            = false

  subscriptions = {
    # Events published with visibility = logistics.delivery.tracking, narrowed
    # to the authorizer. No grant needed: the producer's metadata is consent.
    card-authorizations = {
      visibility = ["logistics.delivery.tracking"]
      owner      = local.authorizer
    }
  }
}
