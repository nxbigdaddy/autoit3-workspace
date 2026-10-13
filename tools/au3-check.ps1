<#
.SYNOPSIS
    Syntax-checks AutoIt3 scripts with Au3Check.

.DESCRIPTION
    Au3Check exit codes: 0 = clean, 1 = warnings only, 2 = syntax errors, 3 = usage/input error.
    This wrapper exits 0 when every file is clean or has warnings only, and 2 otherwise.

.EXAMPLE
    .\tools\au3-check.ps1 src\hello.au3

.EXAMPLE
    .\tools\au3-check.ps1 -Path src\*.au3 -ShowIncludes
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string[]]$Path,

    # Extra include search directories passed to Au3Check as -I <dir>.
    [string[]]$IncludeDir = @(),

    # Only errors and warnings.
    [switch]$Quiet,

    # Same as Opt("MustDeclareVars", 1).
    [switch]$MustDeclareVars,

    # Show every include path / file Au3Check resolved.
    [switch]$ShowIncludes
)

. "$PSScriptRoot\_common.ps1"

$checker = Get-Au3CheckPath
$checkArgs = @()
if ($Quiet) { $checkArgs += '-q' }
if ($MustDeclareVars) { $checkArgs += '-d' }
if ($ShowIncludes) { $checkArgs += @('-v', '1') }
foreach ($dir in $IncludeDir) { $checkArgs += @('-I', $dir) }

Write-Host "Au3Check : $checker"

$failed = 0
foreach ($item in $Path) {
    $scriptPath = Resolve-ScriptPath -Path $item
    Write-Host ''
    Write-Host "Checking : $scriptPath"

    & $checker @checkArgs $scriptPath
    $code = $LASTEXITCODE

    switch ($code) {
        0 { Write-Host 'Result   : OK (no errors, no warnings)' }
        1 { Write-Host 'Result   : OK (warnings only)' }
        2 { Write-Host 'Result   : FAILED (syntax errors)' }
        default { Write-Host "Result   : FAILED (Au3Check usage/input error, exit $code)" }
    }

    if ($code -ge 2) { $failed++ }
}

Write-Host ''
if ($failed -gt 0) {
    Write-Host "$failed file(s) did not pass the syntax check."
    exit 2
}
Write-Host 'Syntax check passed.'
exit 0
