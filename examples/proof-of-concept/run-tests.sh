#!/usr/bin/env bash
# Runs the ABAC assumptions against the deployed proof of concept.
# Usage: ./run-tests.sh   (from this directory, after `terraform apply`)
#
# Each case states what the design expects. A case passes when the observed
# outcome (allowed / denied) equals the expectation. Anything else that goes
# wrong (throttling, validation, a CLI too old for `eventsv2`) is reported as
# ERROR and never counted as a pass.

set -u
export MSYS_NO_PATHCONV=1 AWS_PAGER=""

if ! aws eventsv2 help >/dev/null 2>&1; then
  echo "This AWS CLI has no 'eventsv2' command. Upgrade the AWS CLI and retry." >&2
  exit 2
fi

eval "$(terraform output -raw test_env | tr -d '\r')"

DATA=$(printf '%s' '{"poc":true}' | base64 | tr -d '\r\n')
pass=0 fail=0 error=0
created=()

assume() { # role_arn [extra sts args...]
  local arn=$1; shift
  local out
  out=$(aws sts assume-role --profile "$SPOKE_PROFILE" --role-arn "$arn" \
    --role-session-name poc "$@" \
    --query 'Credentials.[AccessKeyId,SecretAccessKey,SessionToken]' --output text 2>&1) || {
    ASSUME_ERROR=$out
    return 1
  }
  read -r AK SK ST <<<"$(printf '%s' "$out" | tr -d '\r')"
}

as_role() { # aws args...
  AWS_ACCESS_KEY_ID=$AK AWS_SECRET_ACCESS_KEY=$SK AWS_SESSION_TOKEN=$ST \
    aws --region "$REGION" "$@"
}

report() { # name expected observed detail
  local name=$1 expected=$2 observed=$3 detail=$4
  if [ "$observed" = error ]; then
    error=$((error + 1)); printf 'ERROR  %-46s expected %-7s\n       %s\n' "$name" "$expected" "$detail"
  elif [ "$observed" = "$expected" ]; then
    pass=$((pass + 1)); printf 'PASS   %-46s %s\n' "$name" "$observed"
  else
    fail=$((fail + 1)); printf 'FAIL   %-46s expected %s, got %s\n       %s\n' "$name" "$expected" "$observed" "$detail"
  fi
}

classify() { # rc output -> allowed | denied | error
  local rc=$1 out=$2
  if printf '%s' "$out" | grep -qi 'AccessDenied'; then echo denied
  elif [ "$rc" -eq 0 ] && ! printf '%s' "$out" | grep -q 'ErrorCode'; then echo allowed
  else echo error; fi
}

publish_case() { # name expected role_arn metadata_json
  local name=$1 expected=$2 role=$3 meta=$4 out rc
  assume "$role" || { report "$name" "$expected" error "$ASSUME_ERROR"; return; }
  out=$(as_role eventsv2 put-raw-events --event-bus-arn "$BUS_ARN" --entries \
    "[{\"Data\":\"$DATA\",\"Metadata\":$meta,\"SystemMetadata\":{\"ContentType\":\"application/json\"}}]" 2>&1)
  rc=$?
  report "$name" "$expected" "$(classify $rc "$out")" "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
}

subscribe_case() { # name expected role_arn subscriber_suffix [filter_json]
  local name=$1 expected=$2 role=$3 sub="$NAME_PREFIX-$4" filter=${5:-} out rc attempt
  assume "$role" || { report "$name" "$expected" error "$ASSUME_ERROR"; return; }
  local args=(eventsv2 create-subscriber --name "$sub" --event-bus-arn "$BUS_ARN"
    --invoke-configuration "{\"TargetArn\":\"$QUEUE_ARN\",\"RoleArn\":\"$DELIVERY_ROLE_ARN\"}"
    --on-failure-configuration "{\"Arn\":\"$DLQ_ARN\"}")
  [ -n "$filter" ] && args+=(--filter-configuration "$filter")
  # One subscriber create or delete runs at a time per bus; retry on conflict.
  for attempt in 1 2 3 4 5 6; do
    out=$(as_role "${args[@]}" 2>&1); rc=$?
    printf '%s' "$out" | grep -q 'ConcurrentModification' || break
    sleep 10
  done
  local observed; observed=$(classify $rc "$out")
  if [ "$observed" = allowed ]; then
    local arn; arn=$(printf '%s' "$out" | grep -o 'arn:aws[^"[:space:]]*:subscriber/[^"[:space:]]*' | head -1)
    [ -n "$arn" ] && created+=("$role|$arn")
  fi
  report "$name" "$expected" "$observed" "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
}

cleanup() {
  local entry role arn attempt out
  for entry in "${created[@]:-}"; do
    [ -z "$entry" ] && continue
    role=${entry%%|*}; arn=${entry#*|}
    assume "$role" || { echo "Could not clean up $arn"; continue; }
    for attempt in 1 2 3 4 5 6; do
      out=$(as_role eventsv2 delete-subscriber --subscriber-arn "$arn" 2>&1) && break
      printf '%s' "$out" | grep -q 'ConcurrentModification' || { echo "Could not delete $arn: $out"; break; }
      sleep 10
    done
  done
}
trap cleanup EXIT

echo "== Publish (PutRawEvents) =="
publish_case "owner publishes its own path"            allowed "$ROLE_OWNER"    "$META_OWNER"
publish_case "owner publishes another service's path"  denied  "$ROLE_OWNER"    "$META_WRONG_LEVEL"
publish_case "owner publishes without the last level"  denied  "$ROLE_OWNER"    "$META_MISSING_LEVEL"
publish_case "stranger publishes as the owner"         denied  "$ROLE_STRANGER" "$META_OWNER"

echo "== Publish (PutEvents envelope, no metadata) =="
assume "$ROLE_OWNER" && {
  out=$(as_role eventsv2 put-events --event-bus-arn "$BUS_ARN" --entries \
    '[{"Source":"poc","DetailType":"Poc","Detail":"{}"}]' 2>&1); rc=$?
  report "owner publishes with PutEvents" denied "$(classify $rc "$out")" "$(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)"
}

echo "== Subscribe (CreateSubscriber) =="
subscribe_case "owner subscribes to its own events"        allowed "$ROLE_OWNER"    own          "$FILTER_OWNER"
subscribe_case "granted consumer subscribes to owner"      allowed "$ROLE_GRANTED"  granted      "$FILTER_OWNER"
subscribe_case "granted consumer subscribes to itself"     allowed "$ROLE_GRANTED"  granted-own  "$FILTER_GRANTED"
subscribe_case "stranger subscribes to owner"              denied  "$ROLE_STRANGER" stranger     "$FILTER_OWNER"
subscribe_case "granted consumer omits the last level"     denied  "$ROLE_GRANTED"  wide         "$FILTER_MISSING_LEVEL"
subscribe_case "stranger subscribes with no filter"        denied  "$ROLE_STRANGER" nofilter

echo "== Tag trust =="
if assume "$ROLE_STRANGER" --tags "Key=$TAG_KEY,Value=authorizer"; then
  report "stranger overrides a tag with a session tag" denied allowed "sts:AssumeRole accepted the session tag"
else
  report "stranger overrides a tag with a session tag" denied \
    "$(printf '%s' "$ASSUME_ERROR" | grep -qi 'AccessDenied' && echo denied || echo error)" \
    "$(printf '%s' "$ASSUME_ERROR" | tr '\n' ' ' | cut -c1-300)"
fi

echo
echo "passed=$pass failed=$fail errors=$error"
[ "$fail" -eq 0 ] && [ "$error" -eq 0 ]
