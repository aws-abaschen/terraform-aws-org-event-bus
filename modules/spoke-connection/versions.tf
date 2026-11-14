terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
    # Creates the subscribers. This provider must authenticate as a principal
    # that carries the hierarchy tags of var.path: the bus policy authorizes
    # CreateSubscriber against the caller's tags. See the module README.
    awscc = {
      source  = "hashicorp/awscc"
      version = ">= 1.0"
    }
  }
}
