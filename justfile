# Linux/macOS: just <task>. Windows (PowerShell): just win::<task>, see win.just.
# Every task here is offline: no AWS credentials, nothing is applied.
mod win

modules := "modules/central-bus modules/spoke-connection modules/central-bus-classic modules/spoke-connection-classic"
examples := "examples/classic examples/complete examples/deployer-role examples/guardrails examples/proof-of-concept"

default:
    @just --list

fmt:
    terraform fmt -recursive

# Format check, then validate every module and example
validate:
    #!/usr/bin/env bash
    set -euo pipefail
    terraform fmt -check -recursive
    for dir in {{modules}} {{examples}}; do
      echo "== $dir"
      terraform -chdir="$dir" init -backend=false -input=false >/dev/null
      terraform -chdir="$dir" validate
    done

# validate, then the mocked-provider tests of both modules
test: validate
    #!/usr/bin/env bash
    set -euo pipefail
    for dir in {{modules}}; do
      echo "== $dir"
      terraform -chdir="$dir" test
    done

# TFLint with the AWS ruleset
lint:
    tflint --init
    tflint --recursive --format compact

# Checkov and Trivy: AWS best-practice and security checks (pip install checkov==3.4.5)
scan:
    checkov --config-file .checkov.yaml
    trivy config --exit-code 1 --severity LOW,MEDIUM,HIGH,CRITICAL --skip-dirs .terraform .

# Everything CI runs
check: test lint scan
