terraform {
  required_version = ">= 1.9"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = ">= 6.0"
    }
    # The Custom Event Bus has no resource in hashicorp/aws yet. awscc is
    # generated from the CloudFormation schema (AWS::EventsV2::*).
    awscc = {
      source  = "hashicorp/awscc"
      version = ">= 1.0"
    }
  }
}
