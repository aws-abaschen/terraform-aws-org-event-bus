# One platform account and two workload accounts.
#
#   payments account:  authorizer  publishes, and reads its own events
#   logistics account: tracker     reads authorizer's events through a grant
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

module "central_bus" {
  source = "../../modules/central-bus"
  providers = {
    aws   = aws.platform
    awscc = awscc.platform
  }

  name            = "org"
  organization_id = var.organization_id
  hierarchy       = local.hierarchy

  platforms = {
    payments  = { account_ids = [var.payments_account_id] }
    logistics = { account_ids = [var.logistics_account_id] }
  }

  # The allow-list. In a real estate, load these from one file per owner
  # service and make the owning team the required reviewer of its file.
  grants = [
    { owner = local.authorizer, consumer = local.tracker },
  ]
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
  path            = local.tracker

  vpc_id     = var.logistics_vpc_id
  subnet_ids = var.logistics_subnet_ids

  assume_role_policy = local.ecs_trust
  publish            = false

  subscriptions = {
    card-authorizations = { owner = local.authorizer } # allowed by the grant above
  }
}
