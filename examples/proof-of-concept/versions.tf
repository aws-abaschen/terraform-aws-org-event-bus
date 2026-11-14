terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
    # The new Custom Event Bus has no resource in hashicorp/aws yet. awscc is
    # generated from the CloudFormation schema (AWS::EventsV2::*).
    awscc = {
      source  = "hashicorp/awscc"
      version = ">= 1.0"
    }
  }
}

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

provider "aws" {
  alias   = "spoke"
  region  = var.region
  profile = var.spoke_profile
}
