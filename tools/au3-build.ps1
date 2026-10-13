<#
.SYNOPSIS
    Compiles an AutoIt3 script into a standalone .exe with Aut2Exe.

.DESCRIPTION
    Wrap of the Aut2Exe command line:
      Aut2Exe.exe /in <infile.au3> [/out <outfile.exe>] [/icon <icon.ico>] [/comp 0-4]
                  [/ignoredirectives] [/nopack] [/pack] [/ansi] [/unicode] [/x64]
                  [/console] [/gui] [/execlevel <...>] [/pass <password>]

    Default output is <workspace>\build\<scriptname>.exe.

.EXAMPLE
    .\tools\au3-build.ps1 src\hello.au3

.EXAMPLE
    .\tools\au3-build.ps1 src\hello.au3 -Arch x64 -Type console -Upx nopack
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$Path,

    # Output .exe path. Default: <workspace>\build\<script name>.exe
    [string]$Out,

    [ValidateSet('x86', 'x64')]
    [string]$Arch = 'x86',

    # /gui (default) or /console.
    [ValidateSet('gui', 'console')]
    [string]$Type = 'gui',

    # Path to an .ico file.
    [string]$Icon,

    # /comp 0-4 (0 = none, 4 = max).
    [ValidateRange(0, 4)]
    [int]$Compression = 2,

    # UPX packing: default (let Aut2Exe decide), pack, nopack.
    [ValidateSet('default', 'pack', 'nopack')]
    [string]$Upx = 'default',

    [ValidateSet('unicode', 'ansi')]
    [string]$Charset = 'unicode',

    # /pass <password> - the exe will ask for it at runtime.
    [string]$Password,

    # /execlevel - UAC manifest level.
    [ValidateSet('none', 'asinvoker', 'highestavailable', 'requireadministrator')]
    [string]$ExecLevel = 'none',

    # Ignore #pragma compile(...) directives inside the script.
    [switch]$IgnoreDirectives,

    # Extra raw Aut2Exe switches, e.g. -ExtraArgs '/companyname','ACME'
    [string[]]$ExtraArgs = @(),

    [int]$TimeoutSec = 180
)

. "$PSScriptRoot\_common.ps1"

$scriptPath = Resolve-ScriptPath -Path $Path
$name = [System.IO.Path]::GetFileNameWithoutExtension($scriptPath)

# Encoding warning: AutoIt needs a UTF-8 BOM to reliably read sources that
# contain non-ASCII text. Without it, string literals can be mis-decoded and the
# compiled exe misbehaves. (Keep this file ASCII-only: Windows PowerShell 5.1
# reads BOM-less .ps1 files as ANSI, so non-ASCII here would break the script.)
$bytes = [System.IO.File]::ReadAllBytes($scriptPath)
$hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
if (-not $hasBom) {
    $hasNonAscii = $false
    foreach ($b in $bytes) {
        if ($b -gt 0x7F) { $hasNonAscii = $true; break }
    }
    if ($hasNonAscii) {
        Write-Host 'WARNING: source has non-ASCII text but no UTF-8 BOM - Chinese literals may be broken.' -ForegroundColor Yellow
        Write-Host '         Run first:  .\tools\au3-encoding.ps1 -Path src -Fix' -ForegroundColor Yellow
        Write-Host ''
    }
}

if (-not $Out) {
    $Out = Join-Path (Join-Path (Get-WorkspaceRoot) 'build') ($name + '.exe')
}
$outFull = Resolve-FullPath -Path $Out
$outDir = Split-Path -Parent $outFull
if (-not (Test-Path -LiteralPath $outDir)) {
    [void](New-Item -ItemType Directory -Path $outDir -Force)
}
# Aut2Exe refuses (or prompts) when the target already exists.
if (Test-Path -LiteralPath $outFull) { Remove-Item -LiteralPath $outFull -Force }

$iconFull = $null
if ($Icon) {
    $iconFull = Resolve-FullPath -Path $Icon
    if (-not (Test-Path -LiteralPath $iconFull -PathType Leaf)) { throw "Icon file not found: $iconFull" }
}

$aut2exe = Get-Aut2ExePath -Arch $Arch

$buildArgs = @('/in', (Format-Arg $scriptPath), '/out', (Format-Arg $outFull), '/comp', "$Compression")
if ($Type -eq 'console') { $buildArgs += '/console' } else { $buildArgs += '/gui' }
if ($Charset -eq 'ansi') { $buildArgs += '/ansi' } else { $buildArgs += '/unicode' }
if ($Arch -eq 'x64') { $buildArgs += '/x64' }
switch ($Upx) {
    'pack' { $buildArgs += '/pack' }
    'nopack' { $buildArgs += '/nopack' }
}
if ($iconFull) { $buildArgs += @('/icon', (Format-Arg $iconFull)) }
if ($Password) { $buildArgs += @('/pass', (Format-Arg $Password)) }
if ($ExecLevel -ne 'none') { $buildArgs += @('/execlevel', $ExecLevel) }
if ($IgnoreDirectives) { $buildArgs += '/ignoredirectives' }
if ($ExtraArgs.Count -gt 0) { $buildArgs += $ExtraArgs }

Write-Host "Compiler    : $aut2exe"
Write-Host "Source      : $scriptPath"
Write-Host "Target      : $outFull   [$Arch / $Type / comp=$Compression / upx=$Upx]"
Write-Host ''

$result = Invoke-NativeAndWait -FilePath $aut2exe -Arguments $buildArgs -TimeoutSec $TimeoutSec -CaptureOutput

if ($result.StdOut) { Write-Host $result.StdOut.TrimEnd() }
if ($result.StdErr) { Write-Host $result.StdErr.TrimEnd() }

if ($result.ExitCode -ne 0) {
    Write-Host "Compile FAILED - Aut2Exe exit code $($result.ExitCode)"
    exit 1
}
if (-not (Test-Path -LiteralPath $outFull -PathType Leaf)) {
    Write-Host 'Compile FAILED - Aut2Exe reported success but produced no output file.'
    exit 1
}

$item = Get-Item -LiteralPath $outFull
Write-Host ("Compile OK  - {0:N0} bytes" -f $item.Length)
exit 0
