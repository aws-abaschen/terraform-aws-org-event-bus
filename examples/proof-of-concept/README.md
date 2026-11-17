# Proof of concept: hierarchy ABAC on the Custom Event Bus

Settles assumptions 1, 5 and 6 of the [design](../../README.md#assumptions-to-prove), and
reports the policy size for assumption 2. It does not create VPC endpoints, so assumption 3 is
out of scope here.

> Written from the AWS documentation and validated with `terraform validate` only. It has not
> been applied.

## What it deploys

| Account | Resources |
|---|---|
| Platform | One Custom Event Bus (1 day retention) and its `default` resource policy, generated from `var.hierarchy` |
| Spoke | Three IAM roles tagged with a hierarchy path (`owner`, `granted`, `stranger`), a delivery role, an SQS queue and a dead-letter queue |

The two accounts must be different. In a single account the role's identity policy would allow
the calls on its own and the bus policy's Allow statements would not be tested.

## What it tests

`run-tests.sh` assumes each role in turn and checks the outcome against the design.

| Case | Expected |
|---|---|
| Owner publishes its own path | allowed |
| Owner publishes with another service name | denied |
| Owner publishes without the last level | denied |
| Stranger publishes as the owner | denied |
| Owner publishes its own path with a `visibility` key | allowed |
| Owner publishes with `PutEvents` (no metadata) | denied |
| Owner subscribes to its own events | allowed |
| Granted consumer subscribes to the owner's events | allowed |
| Granted consumer subscribes to its own events | allowed |
| Stranger subscribes to the owner's events | denied |
| Granted consumer omits the last level from its filter | denied |
| Stranger subscribes with no filter | denied |
| Granted consumer (same solution) subscribes to `visibility = payments.cards` | allowed |
| Stranger (other platform) subscribes to `visibility = payments.cards` | denied |
| Stranger subscribes to `visibility = public` | allowed |
| Stranger subscribes to `visibility` in `payments.cards` or `public` | denied |
| Stranger adds a second filter naming the owner's path next to a `public` one | denied |
| Stranger passes a session tag to override its role tag | denied |

A case that fails for any other reason (throttling, validation, an old CLI) is reported as
`ERROR` and never counted as a pass.

## Run it

Requirements: Terraform 1.9 or later, an AWS CLI version that has the `eventsv2` command, bash
(Git Bash on Windows), and two CLI profiles with administrator access to two accounts.

```bash
terraform init
```

```bash
terraform apply -var platform_profile=PLATFORM -var spoke_profile=SPOKE
```

```bash
./run-tests.sh
```

```bash
terraform destroy -var platform_profile=PLATFORM -var spoke_profile=SPOKE
```

The script deletes the subscribers it created. State is local; do not commit it.

## Reading the result

- **All pass:** the tag-variable design holds across accounts. Build the modules as designed.
- **Publish cases fail:** `events:Metadata/<key>` cannot be compared with
  `${aws:PrincipalTag/<key>}` on `PutRawEvents`. Use the fallback in the design README.
- **Only visibility cases fail:** a metadata key outside the hierarchy, or a condition value
  joining several tag variables, does not work. Fall back to `grants`, or to one visibility key
  per level compared with a single tag variable each.
- **The two-filter case is allowed:** a subscriber's filters are not all checked, so a second
  filter bypasses every subscribe rule. Subscribers must then be created by a control plane on
  the consumers' behalf.
- **Only subscribe cases fail:** the variable works for single values but not with
  `ForAllValues` on subscriber filters. Own-event subscriptions then need one literal statement
  per service, which brings the policy size limit forward.
