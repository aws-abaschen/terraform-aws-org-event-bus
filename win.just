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
