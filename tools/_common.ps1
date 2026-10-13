<#
    _common.ps1 - shared helpers for the AutoIt3 workspace tooling.
    Dot-source it from the other scripts:   . "$PSScriptRoot\_common.ps1"
    Windows PowerShell 5.1 compatible (no PS7-only syntax).
#>

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Workspace root = parent directory of this tools\ folder.
$script:WorkspaceRoot = Split-Path -Parent $PSScriptRoot

function Get-WorkspaceRoot {
    return $script:WorkspaceRoot
}

function Get-AutoItHome {
    $candidates = New-Object System.Collections.Generic.List[string]
    if ($env:AUTOIT_HOME) { $candidates.Add($env:AUTOIT_HOME) }
    if (${env:ProgramFiles(x86)}) { $candidates.Add((Join-Path ${env:ProgramFiles(x86)} 'AutoIt3')) }
    if ($env:ProgramFiles) { $candidates.Add((Join-Path $env:ProgramFiles 'AutoIt3')) }
    $candidates.Add('C:\AutoIt3')

    foreach ($key in @('HKLM:\SOFTWARE\WOW6432Node\AutoIt v3\AutoIt', 'HKLM:\SOFTWARE\AutoIt v3\AutoIt')) {
        $dir = $null
        try { $dir = (Get-ItemProperty -Path $key -Name InstallDir -ErrorAction Stop).InstallDir } catch { $dir = $null }
        if ($dir) { $candidates.Add($dir) }
    }

    foreach ($candidate in $candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            $exe = Join-Path $candidate 'AutoIt3.exe'
            if (Test-Path -LiteralPath $exe -PathType Leaf) {
                return (Resolve-Path -LiteralPath $candidate).Path
            }
        }
    }

    throw 'AutoIt3 not found. Install AutoIt3, or set the AUTOIT_HOME environment variable to the install folder.'
}

function Get-AutoItExePath {
    param([ValidateSet('x86', 'x64')][string]$Arch = 'x86')

    $autoItHome = Get-AutoItHome
    if ($Arch -eq 'x64') {
        $x64 = Join-Path $autoItHome 'AutoIt3_x64.exe'
        if (Test-Path -LiteralPath $x64 -PathType Leaf) { return $x64 }
    }
    return (Join-Path $autoItHome 'AutoIt3.exe')
}

function Get-Aut2ExePath {
    param([ValidateSet('x86', 'x64')][string]$Arch = 'x86')

    $dir = Join-Path (Get-AutoItHome) 'Aut2Exe'
    if ($Arch -eq 'x64') {
        $p64 = Join-Path $dir 'Aut2exe_x64.exe'
        if (Test-Path -LiteralPath $p64 -PathType Leaf) { return $p64 }
    }
    $p = Join-Path $dir 'Aut2exe.exe'
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "Aut2exe.exe not found in $dir" }
    return $p
}

function Get-Au3CheckPath {
    $p = Join-Path (Get-AutoItHome) 'Au3Check.exe'
    if (-not (Test-Path -LiteralPath $p -PathType Leaf)) { throw "Au3Check.exe not found in $(Get-AutoItHome)" }
    return $p
}

function Resolve-ScriptPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = $Path
    if (-not [System.IO.Path]::IsPathRooted($full)) { $full = Join-Path (Get-Location).Path $full }
    if (-not (Test-Path -LiteralPath $full -PathType Leaf)) { throw "Script file not found: $full" }
    return (Resolve-Path -LiteralPath $full).Path
}

function Resolve-FullPath {
    param([Parameter(Mandatory = $true)][string]$Path)

    $full = $Path
    if (-not [System.IO.Path]::IsPathRooted($full)) { $full = Join-Path (Get-Location).Path $full }
    return $full
}

# Wraps a value in double quotes for Aut2Exe's command line.
function Format-Arg {
    param([Parameter(Mandatory = $true)][string]$Value)

    return '"' + $Value + '"'
}

# Starts a process and waits for it, returning its exit code.
#
# This is required for AutoIt3.exe / AutoIt3_x64.exe: they are GUI-subsystem
# binaries, and Windows PowerShell neither waits for them when called with the
# call operator nor sets $LASTEXITCODE for them. Without this wrapper the tool
# scripts would "finish" while the AutoIt script is still running.
#
# With -CaptureOutput stdout/stderr are piped; without it the child inherits the
# console, so ConsoleWrite output appears live and GUI windows behave normally.
function Invoke-NativeAndWait {
    param(
        [Parameter(Mandatory = $true)][string]$FilePath,
        [string[]]$Arguments = @(),
        # 0 = wait forever.
        [int]$TimeoutSec = 0,
        [switch]$CaptureOutput
    )

    $psi = New-Object System.Diagnostics.ProcessStartInfo
    $psi.FileName = $FilePath
    $psi.Arguments = ($Arguments -join ' ')
    $psi.UseShellExecute = $false
    $psi.RedirectStandardOutput = [bool]$CaptureOutput
    $psi.RedirectStandardError = [bool]$CaptureOutput

    $proc = New-Object System.Diagnostics.Process
    $proc.StartInfo = $psi
    [void]$proc.Start()

    $stdoutTask = $null
    $stderrTask = $null
    if ($CaptureOutput) {
        $stdoutTask = $proc.StandardOutput.ReadToEndAsync()
        $stderrTask = $proc.StandardError.ReadToEndAsync()
    }

    if ($TimeoutSec -gt 0) {
        if (-not $proc.WaitForExit($TimeoutSec * 1000)) {
            try { $proc.Kill() } catch { }
            throw "Process timed out after $TimeoutSec second(s) (a dialog box may be waiting): $FilePath"
        }
    } else {
        $proc.WaitForExit()
    }

    $stdout = ''
    $stderr = ''
    if ($CaptureOutput) {
        $stdout = $stdoutTask.Result
        $stderr = $stderrTask.Result
    }

    return [pscustomobject]@{
        ExitCode = $proc.ExitCode
        StdOut   = $stdout
        StdErr   = $stderr
    }
}

function Get-UserIncludeDir {
    $value = $null
    try {
        $value = (Get-ItemProperty -Path 'HKCU:\SOFTWARE\AutoIt v3\AutoIt' -Name Include -ErrorAction Stop).Include
    } catch { $value = $null }
    if ([string]::IsNullOrWhiteSpace($value)) { return $null }
    return $value
}

function Write-Section {
    param([Parameter(Mandatory = $true)][string]$Title)
    Write-Host ''
    Write-Host ('=' * 68)
    Write-Host $Title
    Write-Host ('=' * 68)
}
