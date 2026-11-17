# Checks what the module derives from the hierarchy path. Runs offline with a
# mocked provider: `terraform test`.

mock_provider "aws" {
  mock_data "aws_region" {
    defaults = { region = "eu-west-1" }
  }
  mock_data "aws_vpc" {
    defaults = { cidr_block = "10.0.0.0/16" }
  }
  mock_resource "aws_iam_role" {
    defaults = { arn = "arn:aws:iam::333333333333:role/mock" }
  }
  mock_resource "aws_sqs_queue" {
    defaults = { arn = "arn:aws:sqs:eu-west-1:333333333333:mock" }
  }
}

variables {
  name              = "tracker"
  bus_arn           = "arn:aws:events:eu-west-1:999999999999:event-bus/org"
  organization_id   = "o-a1b2c3d4e5"
  path              = { platform = "logistics", solution = "delivery", product = "tracking", service = "tracker" }
  vpc_id            = "vpc-0abc"
  subnet_ids        = ["subnet-0a", "subnet-0b"]
  delivery_role_arn = "arn:aws:iam::999999999999:role/org-event-delivery"

  assume_role_policy = "{\"Version\":\"2012-10-17\",\"Statement\":[{\"Effect\":\"Allow\",\"Principal\":{\"Service\":\"ecs-tasks.amazonaws.com\"},\"Action\":\"sts:AssumeRole\"}]}"

  queues = {
    own     = {}
    issuing = { visibility_timeout_seconds = 120 }
  }
}

run "derives_tags_source_and_endpoint" {
  command = apply

  assert {
    condition     = aws_iam_role.workload[0].tags == tomap({ platform = "logistics", solution = "delivery", product = "tracking", service = "tracker" })
    error_message = "The workload role must carry one tag per level."
  }

  assert {
    condition     = output.event_source == "logistics.delivery.tracking.tracker"
    error_message = "The source is the path joined with the separator, in hierarchy order."
  }

  assert {
    condition = one([
      for s in jsondecode(aws_iam_role_policy.workload[0].policy).Statement : s if s.Sid == "PublishOwnSourceToCentralBus"
    ]).Condition.StringEquals["events:source"] == "logistics.delivery.tracking.tracker"
    error_message = "The identity policy must limit PutEvents to the service's own source."
  }

  assert {
    condition     = aws_vpc_endpoint.events[0].service_name == "com.amazonaws.eu-west-1.events"
    error_message = "A Classic bus needs the events endpoint service."
  }

  assert {
    condition     = jsondecode(aws_vpc_endpoint.events[0].policy).Statement[0].Resource == var.bus_arn
    error_message = "The endpoint policy must be limited to the central bus."
  }

  assert {
    condition     = jsondecode(aws_sqs_queue_policy.this["own"].policy).Statement[0].Principal.AWS == "arn:aws:iam::999999999999:role/org-event-delivery"
    error_message = "Each queue must admit the central delivery role and nothing else."
  }

  assert {
    condition     = aws_sqs_queue.this["issuing"].name == "tracker-issuing" && aws_sqs_queue.this["issuing"].visibility_timeout_seconds == 120
    error_message = "Queues are named <name>-<key> and take the per-queue settings."
  }
}

run "second_service_in_a_vpc" {
  command = apply

  variables {
    create_endpoints = false
    vpc_id           = null
    subnet_ids       = []
    queues           = {}
    separator        = "/"
  }

  assert {
    condition     = length(aws_vpc_endpoint.events) == 0 && length(aws_security_group.endpoints) == 0
    error_message = "No endpoints when create_endpoints is false."
  }

  assert {
    condition     = output.event_source == "logistics/delivery/tracking/tracker"
    error_message = "The source must follow the separator."
  }

  assert {
    condition     = [for s in jsondecode(aws_iam_role_policy.workload[0].policy).Statement : s.Sid] == ["PublishOwnSourceToCentralBus", "DescribeCentralBus"]
    error_message = "A publish-only service gets no queue permissions."
  }
}

run "rejects_incomplete_path" {
  command = plan

  variables {
    path = { platform = "logistics", solution = "delivery" }
  }

  expect_failures = [var.path]
}

run "rejects_queues_without_delivery_role" {
  command = plan

  variables {
    delivery_role_arn = null
  }

  expect_failures = [aws_sqs_queue.this]
}
