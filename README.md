# terraform-aws-org-event-bus

Organization-wide Amazon EventBridge for AWS Organizations: one central event bus owned by a
platform team, private connectivity from every workload VPC, and attribute-based access control
(ABAC) that follows a configurable business hierarchy such as
**Platform → Solution → Product → Service**.

> **Status: implemented, not yet run against AWS.** Both modules and the examples are written
> and pass `terraform validate` and offline `terraform test`. Nothing has been applied to an AWS
> account, so the items in [Assumptions to prove](#assumptions-to-prove) are still untested.
> Run the [proof of concept](examples/proof-of-concept) first. The research behind the design is
> in [docs/research-eventbridge-org-level.md](docs/research-eventbridge-org-level.md).

## Contents

- [What this repository provides](#what-this-repository-provides)
- [Design decisions](#design-decisions)
- [Level 1: the organization](#level-1-the-organization)
- [Level 2: the ownership hierarchy](#level-2-the-ownership-hierarchy)
- [Level 3: a spoke account and its VPC](#level-3-a-spoke-account-and-its-vpc)
- [Level 4: one event, end to end](#level-4-one-event-end-to-end)
- [Access model](#access-model)
- [Module `central-bus`](#module-central-bus)
- [Module `spoke-connection`](#module-spoke-connection)
- [Organization guardrails](#organization-guardrails)
- [Deployment order](#deployment-order)
- [Testing](#testing)
- [Limits and costs](#limits-and-costs)
- [Assumptions to prove](#assumptions-to-prove)
- [Fallback: Custom Event Bus - Classic](#fallback-custom-event-bus---classic)
- [Repository layout](#repository-layout)

## What this repository provides

Two Terraform modules, deployed by two different teams:

| Module | Deployed by | Deployed in | Purpose |
|---|---|---|---|
| [`modules/central-bus`](#module-central-bus) | Platform team | One event platform account, once per Region | The shared event bus, its organization share, and the generated access policy |
| [`modules/spoke-connection`](#module-spoke-connection) | Each workload team | Each workload account, once per service | Private endpoint to the bus, the workload's tagged IAM role, and its subscriptions |

The rules the two modules enforce together:

1. A workload is a **Service**. Its IAM role carries one tag per hierarchy level.
2. A Service can **publish** only events stamped with its own hierarchy path.
3. A Service can **subscribe** to the events it owns.
4. An owner can **allow-list** other Services to subscribe to its events.
5. The hierarchy itself (level names and depth) is a variable of the central module.

## Design decisions

| Decision | Choice | Why |
|---|---|---|
| Bus type | The EventBridge **Custom Event Bus** launched in September 2026 (`event-busv2`), not Custom Event Bus - Classic | It is the only EventBridge bus whose IAM model exposes publisher-supplied attributes (`events:Metadata/<key>`) on both publish and subscribe. Classic exposes only `source` and `detail-type`. |
| Topology | One bus per Region, opened to the organization by its policy, optionally listed through AWS RAM | Matches current AWS guidance. Classic bus-to-bus forwarding is one hop only and caps at 300 rules per bus. |
| Who owns consumption | Each spoke owns its subscribers, targets and delivery roles | The new bus requires the target to be in the subscriber owner's account, which fits a spoke module. |
| Hierarchy encoding | One event metadata key and one IAM principal tag per level, same names | The policy compares the two directly, so the hierarchy is data, not code. |
| Allow-lists | Declared as reviewed data in the central stack, rendered as explicit policy statements | An allow-list is an entitlement, not an attribute match. Tags on the consumer cannot say which producers it may read. |
| Endpoints | One interface endpoint per spoke VPC | Lets each spoke carry its own least-privilege endpoint policy. |
| Terraform resources for the bus | The `awscc` provider (`awscc_eventsv2_event_bus`, `awscc_eventsv2_resource_policy`, `awscc_eventsv2_subscriber`), isolated behind the module interface | `hashicorp/aws` had no resource for the new bus as of 6.73.0. |

The choice of the new bus is the largest bet in this design. It depends on behaviour AWS documents
but does not demonstrate; see [Assumptions to prove](#assumptions-to-prove) and the
[Classic fallback](#fallback-custom-event-bus---classic).

## Level 1: the organization

The platform account owns the bus and opens it to the organization through the bus policy.
Every workload account reaches it through its own VPC endpoint and consumes through its own
subscribers. Guardrails at organization level make the hierarchy tags trustworthy.

```mermaid
flowchart TB
  subgraph org["AWS Organization"]
    direction TB

    subgraph mgmt["Management account"]
      scp["SCP: only the provisioning role<br/>may set hierarchy tags"]
      rcp["RCP: event buses accept<br/>organization principals only"]
    end

    subgraph platform["Event platform account - module central-bus"]
      bus[["Central event bus"]]
      policy["Generated bus policy<br/>publish guardrails + allow-lists"]
      share["AWS RAM share<br/>optional, for discovery"]
      policy --- bus
      share --- bus
    end

    subgraph spokeA["Workload account A - module spoke-connection"]
      vpcA["VPC + interface endpoint"]
      subA["Subscribers + SQS targets"]
    end

    subgraph spokeB["Workload account B - module spoke-connection"]
      vpcB["VPC + interface endpoint"]
      subB["Subscribers + SQS targets"]
    end

    subgraph spokeC["Workload account C - module spoke-connection"]
      vpcC["VPC + interface endpoint"]
      subC["Subscribers + SQS targets"]
    end
  end

  vpcA -- "publish" --> bus
  vpcB -- "publish" --> bus
  vpcC -- "publish" --> bus
  bus -- "deliver" --> subA
  bus -- "deliver" --> subB
  bus -- "deliver" --> subC
  scp -. "applies to" .-> spokeA
  scp -. "applies to" .-> spokeB
  scp -. "applies to" .-> spokeC
  rcp -. "applies to" .-> platform
```

The bus and everything that publishes to it or subscribes to it must be in the same Region. A
multi-Region estate deploys `central-bus` once per Region.

## Level 2: the ownership hierarchy

The hierarchy is a list of level names passed to `central-bus`. The default is
`["platform", "solution", "product", "service"]`. An AWS account is owned by exactly one
top-level unit (a Platform). A workload role is one leaf (a Service) and is identified by its
full path.

```mermaid
flowchart TB
  subgraph payments["Platform: payments"]
    direction TB
    accP1(["Account 111111111111"])
    accP2(["Account 222222222222"])

    subgraph cards["Solution: cards"]
      subgraph issuing["Product: issuing"]
        svcAuth["Service: authorizer<br/>IAM role"]
        svcLedger["Service: ledger<br/>IAM role"]
      end
      subgraph disputes["Product: disputes"]
        svcCase["Service: case-manager<br/>IAM role"]
      end
    end
  end

  subgraph logistics["Platform: logistics"]
    direction TB
    accL1(["Account 333333333333"])

    subgraph delivery["Solution: delivery"]
      subgraph tracking["Product: tracking"]
        svcTrack["Service: tracker<br/>IAM role"]
      end
    end
  end

  svcAuth -- "owns and publishes" --> evtAuth{{"payments / cards / issuing / authorizer"}}
  evtAuth -- "own events" --> svcAuth
  evtAuth -- "allow-listed by owner" --> svcCase
  evtAuth -- "allow-listed by owner" --> svcTrack
```

The same vocabulary appears in three places, and the module keeps them aligned:

| Plane | Carrier | Example |
|---|---|---|
| Identity | IAM role tags, read as `aws:PrincipalTag/<level>` | `platform=payments`, `solution=cards`, `product=issuing`, `service=authorizer` |
| Event | Metadata keys set by the publisher on `PutRawEvents`, read as `events:Metadata/<level>` | same four keys and values |
| Account | `aws:PrincipalAccount`, checked against the accounts registered for the Platform | `111111111111` belongs to `payments` |

The account check exists because it is the one attribute a team cannot forge: a role in a
`logistics` account that somehow carries `platform=payments` is still denied.

## Level 3: a spoke account and its VPC

The workload has no internet access. It publishes through an EventBridge interface endpoint in
its own VPC. Delivery never enters the VPC: EventBridge writes to a queue in the spoke account
over the AWS network, and the workload reads the queue through the SQS endpoint.

```mermaid
flowchart LR
  subgraph spoke["Workload account"]
    direction LR

    subgraph vpc["Workload VPC - private subnets"]
      wl["Workload<br/>assumes the Service role"]
      vpceEvents["Interface endpoint<br/>eventsv2"]
      vpceSqs["Interface endpoint<br/>sqs"]
    end

    role["Service role<br/>hierarchy tags + identity policy"]
    epPolicy["Endpoint policy<br/>central bus ARN only,<br/>organization principals only"]
    sub["Subscriber<br/>metadata filter"]
    delivery["Delivery role"]
    queue[("SQS queue")]
    dlq[("Dead-letter queue")]
  end

  subgraph platform["Event platform account"]
    bus[["Central event bus"]]
  end

  wl -. "uses" .-> role
  epPolicy --- vpceEvents
  wl -- "1. PutRawEvents" --> vpceEvents
  vpceEvents -- "2. AWS PrivateLink" --> bus
  bus -- "3. matched events" --> sub
  sub -- "4. deliver" --> queue
  sub -. "assumes" .-> delivery
  sub -. "on failure" .-> dlq
  wl -- "5. ReceiveMessage" --> vpceSqs
  vpceSqs --> queue
```

Three independent gates must all allow a publish: the role's identity policy, the endpoint
policy, and the bus policy.

## Level 4: one event, end to end

### Publishing

```mermaid
sequenceDiagram
  autonumber
  participant W as Workload<br/>authorizer role
  participant E as VPC endpoint<br/>spoke account
  participant B as Central event bus<br/>platform account
  participant S as Subscribers

  W->>E: PutRawEvents with metadata<br/>platform, solution, product, service
  E->>E: Endpoint policy: is the target the central bus?<br/>is the caller in the organization?
  E->>B: Forward over PrivateLink
  B->>B: Is the caller's account registered<br/>for the Platform in its tag?
  B->>B: Does every metadata level equal<br/>the caller's principal tag?
  alt any check fails
    B-->>W: AccessDenied for the whole batch
  else all checks pass
    B-->>W: Accepted
    B->>S: Deliver to subscribers whose filter matches
  end
```

### Subscribing

Access is decided when a subscriber is created or its filter is updated, not per delivered
event. The filter is the request; the policy decides whether that filter is allowed. The
caller is the consumer's deployment role (the principal Terraform runs as), so that role
carries the service's hierarchy tags.

```mermaid
sequenceDiagram
  autonumber
  participant O as Owner team<br/>authorizer
  participant R as Grants in the central stack<br/>pull request
  participant B as Central event bus
  participant C as Consumer deployment role<br/>tagged as case-manager
  participant Q as Consumer SQS queue

  O->>R: Add grant: case-manager may read authorizer events
  R->>R: Review, owner team is required approver
  R->>B: terraform apply renders an Allow statement
  C->>B: CreateSubscriber with filter on<br/>authorizer's hierarchy path
  B->>B: Filter names every required level,<br/>exact match only
  B->>B: Own events, or a grant matching<br/>the caller's tags and this path?
  alt allowed
    B-->>C: Subscriber created
    B->>Q: Matching events delivered
  else not allowed
    B-->>C: AccessDenied
  end
  Note over O,B: Removing a grant blocks new subscribers only.<br/>The platform team runs RevokeResource<br/>to stop an existing one.
```

### How the bus policy decides

```mermaid
flowchart TD
  start(["Request reaches the bus"]) --> orgCheck{"Caller in the<br/>organization?"}
  orgCheck -- "no" --> deny(["Deny"])
  orgCheck -- "yes" --> acctCheck{"Caller's account registered<br/>for its platform tag?"}
  acctCheck -- "no" --> deny
  acctCheck -- "yes" --> action{"Action"}

  action -- "PutRawEvents" --> pubCheck{"Every metadata level<br/>equals the caller's tag?"}
  pubCheck -- "no, or a level is missing" --> deny
  pubCheck -- "yes" --> allow(["Allow"])

  action -- "CreateSubscriber<br/>UpdateSubscriber" --> filterCheck{"Filter names every required<br/>level with exact match?"}
  filterCheck -- "no" --> deny
  filterCheck -- "yes" --> ownCheck{"Filter values equal<br/>the caller's tags?"}
  ownCheck -- "yes" --> allow
  ownCheck -- "no" --> grantCheck{"Grant exists for this<br/>caller and this path?"}
  grantCheck -- "yes" --> allow
  grantCheck -- "no" --> deny

  action -- "anything else" --> deny
```

## Access model

### Event shape

Publishers call `PutRawEvents`, because metadata exists only on that API. The hierarchy goes in
metadata; the business payload goes in the data.

```json
{
  "Metadata": {
    "platform": "payments",
    "solution": "cards",
    "product": "issuing",
    "service": "authorizer",
    "event-type": "CardAuthorized",
    "event-version": "1"
  },
  "Data": {
    "authorizationId": "a-7f3c",
    "amount": 4250,
    "currency": "CHF"
  }
}
```

The exact request syntax of `PutRawEvents` is not reproduced here; the block shows the logical
content. `event-type` and `event-version` are conventions of this design, not access attributes.

### Policy statements the central module generates

The statements below show the shape `central-bus` generates. They are **untested against
AWS**. Deny statements also carry an exemption for `exempt_principal_arns` when that is set.

**Publish only what you own.** One Deny per level, because conditions inside one statement are
combined with AND and a mismatch on any single level must deny. Negated operators also match a
missing value, so an event without the key, or a role without the tag, is denied.

```json
{
  "Sid": "PublishOwnServiceLevel",
  "Effect": "Deny",
  "Principal": "*",
  "Action": "events:PutRawEvents",
  "Resource": "arn:aws:events:eu-central-1:999999999999:event-busv2/org",
  "Condition": {
    "StringNotEquals": {
      "events:Metadata/service": "${aws:PrincipalTag/service}"
    }
  }
}
```

**A Platform's tag is only valid in that Platform's accounts.** One statement per Platform.

```json
{
  "Sid": "PaymentsAccountsOnly",
  "Effect": "Deny",
  "Principal": "*",
  "Action": ["events:PutEvents", "events:PutRawEvents", "events:CreateSubscriber", "events:UpdateSubscriber"],
  "Resource": "arn:aws:events:eu-central-1:999999999999:event-busv2/org",
  "Condition": {
    "StringEquals": { "aws:PrincipalTag/platform": "payments" },
    "StringNotEquals": { "aws:PrincipalAccount": ["111111111111", "222222222222"] }
  }
}
```

A further Deny rejects any principal whose `platform` tag is missing or names no registered
Platform.

**Subscribe to your own events.** Constant size, whatever the number of services. The `Null`
check closes a documented bypass: without it, a filter that omits a key passes
`ForAllValues`.

```json
{
  "Sid": "SubscribeOwnEvents",
  "Effect": "Allow",
  "Principal": "*",
  "Action": ["events:CreateSubscriber", "events:UpdateSubscriber"],
  "Resource": "arn:aws:events:eu-central-1:999999999999:event-busv2/org",
  "Condition": {
    "StringEquals": {
      "aws:PrincipalOrgID": "o-exampleorgid",
      "events:Metadata/platform/Matcher": "exact",
      "events:Metadata/solution/Matcher": "exact",
      "events:Metadata/product/Matcher": "exact",
      "events:Metadata/service/Matcher": "exact"
    },
    "Null": {
      "events:Metadata/platform": "false",
      "events:Metadata/solution": "false",
      "events:Metadata/product": "false",
      "events:Metadata/service": "false"
    },
    "ForAllValues:StringEquals": {
      "events:Metadata/platform": "${aws:PrincipalTag/platform}",
      "events:Metadata/solution": "${aws:PrincipalTag/solution}",
      "events:Metadata/product": "${aws:PrincipalTag/product}",
      "events:Metadata/service": "${aws:PrincipalTag/service}"
    }
  }
}
```

**Allow-list.** One statement per grant, with literal values on both sides: the owner's path in
the filter conditions, the consumer's path in the principal-tag conditions.

```json
{
  "Sid": "GrantAuthorizerToCaseManager",
  "Effect": "Allow",
  "Principal": "*",
  "Action": ["events:CreateSubscriber", "events:UpdateSubscriber"],
  "Resource": "arn:aws:events:eu-central-1:999999999999:event-busv2/org",
  "Condition": {
    "StringEquals": {
      "aws:PrincipalOrgID": "o-exampleorgid",
      "aws:PrincipalTag/platform": "payments",
      "aws:PrincipalTag/solution": "cards",
      "aws:PrincipalTag/product": "disputes",
      "aws:PrincipalTag/service": "case-manager",
      "events:Metadata/platform/Matcher": "exact",
      "events:Metadata/solution/Matcher": "exact",
      "events:Metadata/product/Matcher": "exact",
      "events:Metadata/service/Matcher": "exact"
    },
    "Null": {
      "events:Metadata/platform": "false",
      "events:Metadata/solution": "false",
      "events:Metadata/product": "false",
      "events:Metadata/service": "false"
    },
    "ForAllValues:StringEquals": {
      "events:Metadata/platform": "payments",
      "events:Metadata/solution": "cards",
      "events:Metadata/product": "issuing",
      "events:Metadata/service": "authorizer"
    }
  }
}
```

### Properties worth knowing

- **Subscribe rights are not granted through RAM.** RAM managed permissions carry no
  conditions, so a RAM `SubscribeOnly` grant would let any account subscribe to anything. The
  bus policy grants subscribe, and allow-lists are closed by default.
- **`PutEvents` is denied by default.** That API carries no metadata, so it would bypass the
  hierarchy.
- **Subscribe checks run at create and update only.** Tightening the policy or removing a grant
  does not stop an existing subscriber. The bus owner stops one with `RevokeResource`.
- **Wider scopes are a filter with fewer keys.** Metadata filters are exact match only. A grant
  on a whole Product is a grant whose `owner` stops at `product`. `own_read_scope` on the bus
  does the same for reading without a grant.
- **A batch is all or nothing.** One entry with wrong metadata denies the whole `PutRawEvents`
  call.

## Module `central-bus`

Deployed once per Region in the event platform account. Not the management account: resource
control policies do not apply there.

**Creates**

- The event bus, with retention and an optional customer managed KMS key.
- The bus policy, generated from the hierarchy, the Platform account registry and the grants.
  The plan fails if the policy exceeds the size quota.
- Optionally an AWS RAM share (publish only), which makes the bus discoverable in the
  accounts it is shared with. Access itself comes from the bus policy.

**Inputs**

| Name | Type | Default | Description |
|---|---|---|---|
| `name` | `string` | required | Bus name. |
| `organization_id` | `string` | required | Limits every Allow statement to the organization. |
| `platforms` | `map(object({ account_ids }))` | required | Top-level units and the accounts each one owns. |
| `hierarchy` | `list(string)` | `["platform", "solution", "product", "service"]` | Level names, top to bottom. Drives metadata keys, tag keys and conditions. |
| `tag_key_prefix` | `string` | `""` | Prefix for the IAM tag keys. Metadata keys are never prefixed. |
| `own_read_scope` | `string` | last level | Level down to which a principal may subscribe without a grant. |
| `grants` | `list(object({ owner, consumer }))` | `[]` | Allow-list. Both sides are a prefix of the hierarchy, so a grant can name one service or everything below a higher level. |
| `exempt_principal_arns` | `list(string)` | `[]` | Principals exempt from the Deny guardrails (platform operators, forwarders of AWS service events). |
| `allow_put_events` | `bool` | `false` | Allow the `PutEvents` envelope API, which carries no metadata. |
| `share_with` | `list(string)` | `[]` | Organization, OU or account principals for the optional RAM share. |
| `retention_days` | `number` | `7` | Event retention, 1 to 365. |
| `kms_key_arn` | `string` | `null` | Customer managed key. |
| `policy_size_limit` | `number` | `20480` | Policy size quota in bytes. |
| `tags` | `map(string)` | `{}` | Tags for the bus and the share. |

**Outputs:** `bus_arn`, `bus_name`, `hierarchy`, `tag_key_prefix`, `tag_keys`, `policy_json`,
`policy_bytes`, `ram_share_arn`.

**Example**

```hcl
module "central_bus" {
  source = "github.com/aws-abaschen/terraform-aws-org-event-bus//modules/central-bus"

  name            = "org"
  organization_id = "o-exampleorgid"

  hierarchy = ["platform", "solution", "product", "service"]

  platforms = {
    payments  = { account_ids = ["111111111111", "222222222222"] }
    logistics = { account_ids = ["333333333333"] }
  }

  grants = [
    {
      # One service to one service.
      owner    = { platform = "payments", solution = "cards", product = "issuing", service = "authorizer" }
      consumer = { platform = "payments", solution = "cards", product = "disputes", service = "case-manager" }
    },
    {
      # A whole product to a whole platform.
      owner    = { platform = "payments", solution = "cards", product = "issuing" }
      consumer = { platform = "logistics" }
    },
  ]
}
```

**How owners allow-list consumers.** Keep grants as files in the central stack (for example one
YAML file per owner service under `grants/`) and load them into `grants`. A `CODEOWNERS` entry
makes the owning team the required reviewer of its own file. The pull request is the approval
workflow; EventBridge has none of its own.

## Module `spoke-connection`

Deployed once per service, in the service's account. The first service in a VPC creates the
endpoints; later ones set `create_endpoints = false`.

**Creates**

- The EventBridge interface endpoint (`eventsv2`) with private DNS, its security group, and an
  endpoint policy limited to the central bus and to organization principals. Optionally the SQS
  interface endpoint.
- The workload IAM role, tagged with the hierarchy path, allowed to publish to the bus and to
  read its subscription queues.
- For each subscription: a subscriber with a metadata filter, an SQS queue, a dead-letter
  queue and a shared delivery role, all in the service's account.

**Who runs it matters.** The bus policy authorizes `CreateSubscriber` against the tags of the
principal that makes the call, which is the principal Terraform runs as, not the workload
role. Each service therefore needs a **deployment role** tagged with the service's hierarchy
path, and both providers passed to this module must assume it. The guardrail SCP lets a
deployment role create only roles that carry its own tag values, so it can create its
service's workload role and nothing else. See `examples/deployer-role`.

**Inputs**

| Name | Type | Default | Description |
|---|---|---|---|
| `name` | `string` | required | Service short name. Prefix for the role, queues and subscribers. |
| `bus_arn` | `string` | required | Output of `central-bus`. |
| `organization_id` | `string` | required | Used in the endpoint policy. |
| `path` | `map(string)` | required | One value per hierarchy level. |
| `hierarchy` | `list(string)` | same default as `central-bus` | Must equal the central module's value. |
| `tag_key_prefix` | `string` | `""` | Must equal the central module's value. |
| `create_endpoints` | `bool` | `true` | Create the interface endpoints. |
| `vpc_id`, `subnet_ids` | `string`, `list(string)` | `null`, `[]` | Where the endpoints go. |
| `endpoint_ingress_cidr_blocks` | `list(string)` | VPC CIDR | Who may reach the endpoints on 443. |
| `create_sqs_endpoint` | `bool` | `true` | Also create the SQS endpoint. |
| `enable_endpoint_policy` | `bool` | `true` | Attach the endpoint policy. |
| `endpoint_allowed_actions` | `list(string)` | publish and describe | Actions allowed through the endpoint. |
| `create_role` | `bool` | `true` | Create the workload role. |
| `assume_role_policy` | `string` | `null` | Trust policy of the workload role. Must not allow `sts:TagSession`. |
| `permissions_boundary` | `string` | `null` | Boundary for the roles the module creates. |
| `publish` | `bool` | `true` | Allow the workload role to publish. |
| `subscriptions` | `map(object)` | `{}` | Per subscription: optional `owner` path prefix (default: this service), `transformer_type` (`WITH_METADATA` or `RAW`), queue timings. |
| `tags` | `map(string)` | `{}` | Tags for every resource. |

Subscribing to another owner's events succeeds only if the central stack holds a matching
grant.

**Outputs:** `role_arn`, `role_name`, `hierarchy_tags`, `event_metadata`, `events_endpoint_id`,
`sqs_endpoint_id`, `endpoint_security_group_id`, `queue_arns`, `queue_urls`,
`dead_letter_queue_arns`, `subscriber_arns`.

**Example**

```hcl
provider "aws" {
  region = "eu-west-1"
  assume_role {
    role_arn = "arn:aws:iam::111111111111:role/deploy-case-manager"
  }
}

provider "awscc" {
  region = "eu-west-1"
  assume_role = {
    role_arn = "arn:aws:iam::111111111111:role/deploy-case-manager"
  }
}

module "event_bus_connection" {
  source = "github.com/aws-abaschen/terraform-aws-org-event-bus//modules/spoke-connection"

  name            = "case-manager"
  bus_arn         = "arn:aws:events:eu-west-1:999999999999:event-busv2/org/EXAMPLE1234567890abcdef"
  organization_id = "o-exampleorgid"
  path            = { platform = "payments", solution = "cards", product = "disputes", service = "case-manager" }

  vpc_id     = "vpc-0abc"
  subnet_ids = ["subnet-0a", "subnet-0b"]

  assume_role_policy = data.aws_iam_policy_document.ecs_trust.json

  subscriptions = {
    own            = {}
    authorizations = {
      owner = { platform = "payments", solution = "cards", product = "issuing", service = "authorizer" }
    }
  }
}
```

## Organization guardrails

ABAC on a shared bus is only as sound as the tags. These controls are prerequisites and sit
outside both modules. `examples/guardrails` implements them.

| Control | Type | Effect |
|---|---|---|
| No hierarchy session tags | SCP | Denies `sts:TagSession` with a hierarchy key. Session tags would override role tags. |
| Tag inheritance | SCP | A principal may put a hierarchy tag on an IAM role or user only with the value it carries itself. Untagged principals can set none. |
| No tag removal | SCP | Denies removing a hierarchy tag from a role or user. |
| Organization principals only | RCP | Event buses reject callers outside the organization. Does not cover the management account or service-linked roles. |
| Allowed tag values | Tag policy | Standardizes keys and top-level values. Hygiene only; it does not evaluate untagged resources. |

The account vending or provisioning roles are exempt from the SCP, because they create each
service's deployment role with its tags. Sessions federated through SAML or OIDC are not
subject to the session-tag statement in the same way; make sure the identity provider does not
pass hierarchy keys as session tags.

Organizations account tags are not visible to IAM, which is why the hierarchy is copied onto
roles and the account-to-Platform mapping is passed to `central-bus` explicitly.

## Deployment order

1. **Proof of concept** (`examples/proof-of-concept`): two accounts, confirms the access model.
2. **Guardrails** (`examples/guardrails`): from the management account, before any spoke.
3. **Central bus** (`modules/central-bus`): in the event platform account.
4. **Deployment role per service** (`examples/deployer-role`): by the provisioning role.
5. **Spoke connection per service** (`modules/spoke-connection`): by each service's deployment
   role. `examples/complete` shows steps 3 and 5 wired together.

## Testing

| What | How | Proves |
|---|---|---|
| Module logic | `terraform test` in `modules/central-bus` and `modules/spoke-connection` | The generated policy, tags, filters and endpoint are what the design says. Offline, mocked providers. |
| Access model | `examples/proof-of-concept` (`terraform apply`, then `./run-tests.sh`) | AWS evaluates the policy as intended, across two accounts. Twelve allow and deny cases. |

The module tests pass. The proof of concept has not been run: nothing in this repository has
been applied to an AWS account yet.

## Limits and costs

Figures from the research report; confirm against the live AWS pages before relying on them.

| Item | Value |
|---|---|
| Bus policy size | 20,480 bytes, adjustable. Roughly 40 to 55 grant statements at this design's statement size. |
| Subscribers per bus | 10,000 by default. |
| Buses of this type per account | 5 by default. |
| Throughput | 500,000 events per second per bus. |
| Event size | 1 MB. |
| Subscriber changes | One create or delete in progress per bus across all accounts. |
| Regions | 14 at launch. Bus, publishers and subscribers must share a Region. |
| Pricing | Per GB: publishers pay ingress, subscribers pay egress. |
| Interface endpoint | Billed per endpoint, per Availability Zone, per hour, plus data. |

The policy size is the scaling limit of the allow-list. Past it, grants move out of the bus
policy into a control plane that creates subscribers on behalf of consumers. That is out of
scope for this version.

## Assumptions to prove

Run the proof of concept before relying on the modules. In order of how much design fails
with each:

| # | Assumption | If it fails |
|---|---|---|
| 1 | `events:Metadata/<key>` can be compared with `${aws:PrincipalTag/<key>}` on `PutRawEvents`, `CreateSubscriber` and `UpdateSubscriber`, in a bus policy, for callers in other accounts. AWS's policy language permits it; no AWS example shows it. | Fall back to literal per-service statements keyed on `aws:PrincipalAccount`, or a publish API that stamps metadata from the caller's identity. |
| 2 | The bus policy size fits the expected number of grants. | Bring the control plane forward. |
| 3 | The `eventsv2` interface endpoint supports endpoint policies. | Set `enable_endpoint_policy = false`; rely on identity and bus policies. |
| 4 | The bus is available in the target Region. | Use the Classic fallback in that Region. |
| 5 | Terraform can create several subscribers in one apply despite the one-at-a-time rule. | Apply the spoke with `-parallelism=1`. |
| 6 | The tag-inheritance SCP (a policy variable compared with `aws:RequestTag`) behaves as written. | Restrict tagging to the provisioning roles only and have them create the workload roles. |

## Fallback: Custom Event Bus - Classic

If assumption 1 or 4 fails, the same two-module interface can be implemented on a Classic bus,
with weaker guarantees:

- The hierarchy collapses into one dotted `source` string, for example
  `payments.cards.issuing.authorizer`, enforced with a prefix condition on `events:source`.
- Consumption uses rules on the central bus with direct cross-account targets, so the platform
  account owns every rule (300 rules per bus, 5 targets per rule).
- The interface endpoint is `events` instead of `eventsv2`.
- Native `hashicorp/aws` resources cover everything.

This fallback is not implemented.

## Repository layout

```text
.
├── README.md
├── docs/
│   └── research-eventbridge-org-level.md
├── modules/
│   ├── central-bus/          # bus, generated policy, optional RAM share
│   │   └── tests/
│   └── spoke-connection/     # endpoints, workload role, subscriptions
│       └── tests/
└── examples/
    ├── complete/             # one platform account, two workload accounts
    ├── deployer-role/        # tagged deployment role for one service
    ├── guardrails/           # SCP, RCP and tag policy
    └── proof-of-concept/     # the access-model tests
```
