# Windows recipes in PowerShell 7: just win::<task> (or just win <task>)
set shell := ["pwsh", "-NoLogo", "-NoProfile", "-Command"]

modules := "modules/central-bus modules/spoke-connection modules/central-bus-classic modules/spoke-connection-classic"
examples := "examples/classic examples/complete examples/deployer-role examples/guardrails examples/proof-of-concept"

default:
    @just --list win

fmt:
    terraform fmt -recursive

# Format check, then validate every module and example
validate:
    terraform fmt -check -recursive; if ($LASTEXITCODE) { exit 1 }; foreach ($dir in '{{modules}} {{examples}}'.Split(' ')) { "== $dir"; terraform "-chdir=$dir" init -backend=false -input=false | Out-Null; if ($LASTEXITCODE) { exit 1 }; terraform "-chdir=$dir" validate; if ($LASTEXITCODE) { exit 1 } }

# validate, then the mocked-provider tests of both modules
test: validate
    foreach ($dir in '{{modules}}'.Split(' ')) { "== $dir"; terraform "-chdir=$dir" test; if ($LASTEXITCODE) { exit 1 } }

# TFLint with the AWS ruleset
lint:
    tflint --init; if ($LASTEXITCODE) { exit 1 }; tflint --recursive --format compact

# Checkov and Trivy: AWS best-practice and security checks (pip install checkov==3.4.5)
scan:
    $env:PYTHONIOENCODING = 'utf-8'; python -m checkov.main --config-file .checkov.yaml; if ($LASTEXITCODE) { exit 1 }; trivy config --exit-code 1 --severity LOW,MEDIUM,HIGH,CRITICAL --skip-dirs .terraform .

# Everything CI runs
check: test lint scan
