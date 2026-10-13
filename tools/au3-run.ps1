<#
.SYNOPSIS
    Runs an AutoIt3 script with the interpreter (x86 or x64).

.DESCRIPTION
    Uses the native interpreter, so ConsoleWrite output and the script exit code
    are passed straight through. Arguments after -Path are forwarded to the script
    and appear in AutoIt's $CmdLine array.

    By default the AutoIt switch /ErrorStdOut is used: a runtime error is printed
    to the console and the wrapper exits with code 1 instead of blocking the run
    on a modal message box. Pass -ShowErrorDialog to get the classic AutoIt dialog.

.EXAMPLE
    .\tools\au3-run.ps1 src\hello.au3

.EXAMPLE
    .\tools\au3-run.ps1 src\hello.au3 x64

.EXAMPLE
    .\tools\au3-run.ps1 -Path src\job.au3 -Arch x64 -ScriptArgs 'C:\in.txt', '--dry'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Path,

    [ValidateSet('x86', 'x64')]
    [string]$Arch = 'x86',

    # Show AutoIt's modal error dialog instead of printing errors to the console.
    [switch]$ShowErrorDialog,

    # Arguments handed to the AutoIt script ($CmdLine[1..n]).
    [Parameter(ValueFromRemainingArguments = $true)]
    [string[]]$ScriptArgs = @(),

    # Abort and kill the script after N seconds (0 = wait until it exits).
    [int]$TimeoutSec = 0
)

. "$PSScriptRoot\_common.ps1"

$exe = Get-AutoItExePath -Arch $Arch
$scriptPath = Resolve-ScriptPath -Path $Path

$runArgs = @()
if (-not $ShowErrorDialog) { $runArgs += '/ErrorStdOut' }
$runArgs += $scriptPath
if ($ScriptArgs.Count -gt 0) { $runArgs += $ScriptArgs }

Write-Host "Interpreter : $exe"
Write-Host "Script      : $scriptPath"
if ($ScriptArgs.Count -gt 0) { Write-Host ("Script args : {0}" -f ($ScriptArgs -join ' ')) }
Write-Host ''

$result = Invoke-NativeAndWait -FilePath $exe -Arguments $runArgs -TimeoutSec $TimeoutSec
$code = $result.ExitCode

Write-Host ''
Write-Host "Exit code   : $code"
exit $code
