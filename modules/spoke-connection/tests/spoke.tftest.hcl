# Checks what the module derives from the hierarchy path. Runs offline with
# mocked providers: `terraform test`.

mock_provider "aws" {
  mock_data "aws_region" {
    defaults = { region = "eu-west-1" }
  }
  mock_data "aws_partition" {
    defaults = { partition = "aws" }
  }
  mock_data "aws_caller_identity" {
    defaults = { account_id = "111111111111" }
  }
  mock_data "aws_vpc" {
    defaults = { cidr_block = "10.0.0.0/16" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::111111111111:role/mock" }
  }
  mock_resource "aws_sqs_queue" {
    defaults = { arn = "arn:aws:sqs:eu-west-1:111111111111:mock" }
  }
}

mock_provider "awscc" {}

variables {
  name            = "tracker"
  bus_arn         = "arn:aws:events:eu-west-1:999999999999:event-busv2/org/abcdefghijklmnopqrstuvwxy"
  organization_id = "o-a1b2c3d4e5"
  path            = { platform = "logistics", solution = "delivery", product = "tracking", service = "tracker" }
  vpc_id          = "vpc-0abc"
  subnet_ids      = ["subnet-0a", "subnet-0b"]

  assume_role_policy = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"ecs-tasks.amazonaws.com\"},\"Action\":\"sts:AssumeRole\"}]}"

  subscriptions = {
    own     = {}
    cards   = { owner = { platform = "payments", solution = "cards", product = "issuing", service = "authorizer" } }
    product = { owner = { platform = "payments", solution = "cards", product = "issuing" }, transformer_type = "RAW" }
    shared  = { visibility = ["logistics.delivery", "public"] }
    narrow  = { visibility = ["logistics.delivery.tracking"], owner = { platform = "payments" } }
  }
}

run "derives_tags_filters_and_endpoint" {
  command = apply

  assert {
    condition     = aws_iam_role.workload[0].tags == tomap({ platform = "logistics", solution = "delivery", product = "tracking", service = "tracker" })
    error_message = "The workload role must carry one tag per level."
  }

  assert {
    condition     = aws_vpc_endpoint.events[0].service_name == "com.amazonaws.eu-west-1.eventsv2"
    error_message = "The Custom Event Bus needs the eventsv2 endpoint service."
  }

  assert {
    condition     = jsondecode(aws_vpc_endpoint.events[0].policy).Statement[0].Resource == var.bus_arn
    error_message = "The endpoint policy must be limited to the central bus."
  }

  assert {
    condition = jsondecode(awscc_eventsv2_subscriber.this["own"].filter_configuration.filters[0].pattern) == {
      platform = ["logistics"], solution = ["delivery"], product = ["tracking"], service = ["tracker"]
    }
    error_message = "A subscription without owner must filter on this service's own path."
  }

  assert {
    condition = jsondecode(awscc_eventsv2_subscriber.this["product"].filter_configuration.filters[0].pattern) == {
      platform = ["payments"], solution = ["cards"], product = ["issuing"]
    }
    error_message = "A partial owner must produce a filter on exactly those levels."
  }

  assert {
    condition     = awscc_eventsv2_subscriber.this["cards"].filter_configuration.filters[0].scope == "METADATA"
    error_message = "Hierarchy filters must use the METADATA scope."
  }

  assert {
    condition     = length(aws_sqs_queue.subscription) == 5 && length(aws_sqs_queue.dead_letter) == 5
    error_message = "Each subscription needs a queue and a dead-letter queue."
  }

  assert {
    condition = jsonencode(jsondecode(awscc_eventsv2_subscriber.this["shared"].filter_configuration.filters[0].pattern)) == jsonencode({
      visibility = ["logistics.delivery", "public"]
    })
    error_message = "A visibility subscription without owner must filter on the audiences only, not on this service's path."
  }

  assert {
    condition = jsonencode(jsondecode(awscc_eventsv2_subscriber.this["narrow"].filter_configuration.filters[0].pattern)) == jsonencode({
      platform = ["payments"], visibility = ["logistics.delivery.tracking"]
    })
    error_message = "An owner given with visibility must narrow the filter."
  }

  assert {
    condition = jsonencode(output.visibility_audiences) == jsonencode([
      "logistics", "logistics.delivery", "logistics.delivery.tracking", "logistics.delivery.tracking.tracker", "public",
    ])
    error_message = "The audiences must be the path cut at every level, then the public value."
  }
}

run "second_service_in_a_vpc" {
  command = apply

  variables {
    create_endpoints = false
    vpc_id           = null
    subnet_ids       = []
    subscriptions    = {}
    publish          = true
  }

  assert {
    condition     = length(aws_vpc_endpoint.events) == 0 && length(aws_iam_role.delivery) == 0
    error_message = "No endpoints and no delivery role expected."
  }

  assert {
    condition     = length(jsondecode(aws_iam_role_policy.workload[0].policy).Statement) == 1
    error_message = "A publish-only service needs only the publish statement."
  }
}

run "rejects_incomplete_path" {
  command = plan

  variables {
    path = { platform = "logistics", solution = "delivery" }
  }

  expect_failures = [var.path]
}

run "rejects_foreign_audience" {
  command = plan

  variables {
    subscriptions = {
      peek = { visibility = ["payments.cards"] }
    }
  }

  expect_failures = [var.subscriptions]
}

run "rejects_separator_in_path" {
  command = plan

  variables {
    path = { platform = "logistics", solution = "delivery.tracking", product = "x", service = "tracker" }
  }

  expect_failures = [var.path]
}
