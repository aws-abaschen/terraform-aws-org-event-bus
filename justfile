# Linux/macOS: just <task>. Windows (PowerShell): just win::<task>, see win.just.
# Every task here is offline: no AWS credentials, nothing is applied.
mod win

modules := "modules/account-platforms modules/central-bus modules/spoke-connection"
examples := "examples/complete examples/deployer-role examples/guardrails examples/proof-of-concept"

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
