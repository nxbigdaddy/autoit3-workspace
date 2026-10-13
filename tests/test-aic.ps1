<#
.SYNOPSIS
    AIC console gate: AutoIt self-test + demo run + Python oracle over the written files.

.DESCRIPTION
    1. runs src\AicConsole.au3 /selftest   (config, runs, task board, log, control channel)
    2. runs src\AicConsole.au3 /demo       (builds a synthetic ~/.aic tree)
    3. runs tests\verify_aic.py, which re-parses the written agents.yaml/config.yaml with
       pyyaml and validates control.json with json - an independent check of the write paths.

    Python/pyyaml are optional: if missing, that step is reported as SKIPPED.

.EXAMPLE
    .\tests\test-aic.ps1
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$workspace = Split-Path -Parent $PSScriptRoot
. "$workspace\tools\_common.ps1"

Write-Section 'AIC console: self-test + write-path oracle'

$runner = Join-Path $workspace 'tools\au3-run.ps1'
$console = Join-Path $workspace 'src\AicConsole.au3'
$failures = 0

function Invoke-AutoIt {
    param([string[]]$ScriptArgs)
    Push-Location $workspace
    try {
        & powershell.exe -NoProfile -ExecutionPolicy Bypass -File $runner -Path $console -ScriptArgs $ScriptArgs | Out-Null
        return $LASTEXITCODE
    } finally {
        Pop-Location
    }
}

$selfExit = Invoke-AutoIt -ScriptArgs '/selftest'
if ($selfExit -eq 0) {
    Write-Host 'AIC console self-test   : PASS'
} else {
    Write-Host "AIC console self-test   : FAIL ($selfExit assertion(s))" -ForegroundColor Red
    $failures++
}

# 注意顺序：/selftest 会修改演示目录里的文件，oracle 必须紧跟在它后面，
# 因为 /demo 会重建演示目录（把改动冲掉）。
$oracleDone = $false
$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) {
    Write-Host 'Python oracle           : SKIPPED (python not found)'
} else {
    & $python.Source -c "import yaml" 2>&1 | Out-Null
    if ($LASTEXITCODE -ne 0) {
        Write-Host 'Python oracle           : SKIPPED (pyyaml not installed)'
    } else {
        Push-Location $workspace
        try {
            & $python.Source (Join-Path $workspace 'tests\verify_aic.py') | Out-Null
            $oracleExit = $LASTEXITCODE
        } finally {
            Pop-Location
        }
        $oracleDone = $true
        if ($oracleExit -eq 0) {
            Write-Host 'Python oracle           : PASS'
        } else {
            Write-Host "Python oracle           : FAIL (exit $oracleExit)" -ForegroundColor Red
            $failures++
        }
        $log = Join-Path $workspace 'out\verify-aic.log'
        if (Test-Path -LiteralPath $log) {
            Write-Host ''
            Get-Content -LiteralPath $log -Encoding UTF8 | ForEach-Object { Write-Host "  $_" }
        }
    }
}

$demoExit = Invoke-AutoIt -ScriptArgs '/demo'
if ($demoExit -eq 0) {
    Write-Host 'AIC demo environment    : PASS'
} else {
    Write-Host "AIC demo environment    : FAIL (exit $demoExit)" -ForegroundColor Red
    $failures++
}
if (-not $oracleDone) { Write-Host '(oracle skipped)' }

Write-Host ''
if ($failures -gt 0) {
    Write-Host "AIC gate FAILED ($failures part(s))" -ForegroundColor Red
    exit 1
}
Write-Host 'AIC gate passed.'
exit 0
