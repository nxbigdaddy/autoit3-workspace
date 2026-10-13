<#
.SYNOPSIS
    Parsers gate: runs the AutoIt parser tests and then verifies the round-trip
    results with Python (pyyaml / json) as an independent oracle.

.DESCRIPTION
    1. runs tests\parser-test.au3  (exit code = number of failed assertions)
    2. runs tests\verify_parsers.py, which re-parses the emitted YAML with pyyaml
       and compares it semantically with the originals, and validates control.json

    Python is optional: if it (or pyyaml) is missing the oracle step is reported
    as SKIPPED, not as a failure, so the suite still works on machines without it.

.EXAMPLE
    .\tests\test-parsers.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
. "$workspace\tools\_common.ps1"

Write-Section 'AIC console: parser tests'

$failures = 0

# ---- 1) AutoIt side ---------------------------------------------------------
$runner = Join-Path $workspace 'tools\au3-run.ps1'
$testScript = Join-Path $workspace 'tests\parser-test.au3'
$autoitExit = 0

Push-Location $workspace
try {
    & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -Path $testScript | Out-Null
    $autoitExit = $LASTEXITCODE
} finally {
    Pop-Location
}

if ($autoitExit -eq 0) {
    Write-Host 'AutoIt parser assertions : PASS'
} else {
    Write-Host "AutoIt parser assertions : FAIL ($autoitExit assertion(s))" -ForegroundColor Red
    $failures++
}

# ---- 2) Python oracle ------------------------------------------------------
$python = (Get-Command python -ErrorAction SilentlyContinue)
if (-not $python) {
    Write-Host 'Python oracle            : SKIPPED (python not found)'
} else {
    $hasYaml = & $python.Source -c "import yaml" 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'Python oracle            : SKIPPED (pyyaml not installed)'
    } else {
        Push-Location $workspace
        try {
            & $python.Source (Join-Path $workspace 'tests\verify_parsers.py') | Out-Null
            $oracleExit = $LASTEXITCODE
        } finally {
            Pop-Location
        }

        if ($oracleExit -eq 0) {
            Write-Host 'Python oracle            : PASS'
        } else {
            Write-Host "Python oracle            : FAIL (exit $oracleExit)" -ForegroundColor Red
            $failures++
        }

        $log = Join-Path $workspace 'out\verify-parsers.log'
        if (Test-Path -LiteralPath $log) {
            Write-Host ''
            Get-Content -LiteralPath $log -Encoding UTF8 | ForEach-Object { Write-Host "  $_" }
        }
    }
}

Write-Host ''
if ($failures -gt 0) {
    Write-Host "Parser gate FAILED ($failures part(s))" -ForegroundColor Red
    exit 1
}
Write-Host 'Parser gate passed.'
exit 0
