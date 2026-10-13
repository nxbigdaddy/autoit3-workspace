<#
.SYNOPSIS
    Read-only health check of the AutoIt3 environment and this workspace.

.DESCRIPTION
    Verifies: interpreter/compiler/checker binaries, UDF include set, PATH,
    .au3 file association (including stale targets that point to a deleted
    install), user include folder, SciTE editor integration, AutoItX, editors
    and the workspace folder layout.

    Exit code: 0 = all good, 1 = warnings, 2 = critical problems.

.EXAMPLE
    .\tools\env-doctor.ps1
#>
[CmdletBinding()]
param()

. "$PSScriptRoot\_common.ps1"

$rows = New-Object System.Collections.Generic.List[object]
$problems = 0
$warnings = 0

function Add-Row {
    param(
        [string]$Area,
        [ValidateSet('OK', 'WARN', 'BAD', 'INFO')][string]$Level,
        [string]$Detail
    )
    $rows.Add([pscustomobject]@{ Area = $Area; Level = $Level; Detail = $Detail }) | Out-Null
    if ($Level -eq 'BAD') { $script:problems++ }
    if ($Level -eq 'WARN') { $script:warnings++ }
}

function Get-RegDefaultValue {
    param([string]$Key)
    try { return (Get-Item -LiteralPath $Key -ErrorAction Stop).GetValue('') } catch { return $null }
}

function Get-RegNameValue {
    param([string]$Key, [string]$Name)
    try { return (Get-ItemProperty -LiteralPath $Key -Name $Name -ErrorAction Stop).$Name } catch { return $null }
}

function Get-CommandTarget {
    param([string]$CommandLine)
    if ([string]::IsNullOrWhiteSpace($CommandLine)) { return $null }
    $m = [regex]::Match($CommandLine, '^\s*"([^"]+)"')
    if ($m.Success) { return $m.Groups[1].Value }
    $m = [regex]::Match($CommandLine, '^\s*(\S+)')
    if ($m.Success) { return $m.Groups[1].Value }
    return $null
}

# True when the handler executable exists: absolute paths are checked on disk,
# bare names (for example "cmd.exe") are resolved through PATH.
function Test-CommandTargetExists {
    param([string]$Target)
    if ([string]::IsNullOrWhiteSpace($Target)) { return $false }
    if ([System.IO.Path]::IsPathRooted($Target)) { return (Test-Path -LiteralPath $Target -PathType Leaf) }
    return ($null -ne (Get-Command $Target -ErrorAction SilentlyContinue))
}

Write-Section 'AutoIt3 environment doctor'

# ---------------------------------------------------------------- installation
$autoItHome = $null
try {
    $autoItHome = Get-AutoItHome
    Add-Row 'Install' 'OK' $autoItHome
} catch {
    Add-Row 'Install' 'BAD' $_.Exception.Message
}

if ($autoItHome) {
    foreach ($tool in @(
            @{ Name = 'AutoIt3.exe (x86 interpreter)'; Path = 'AutoIt3.exe' },
            @{ Name = 'AutoIt3_x64.exe (x64 interpreter)'; Path = 'AutoIt3_x64.exe' },
            @{ Name = 'Au3Check.exe (syntax checker)'; Path = 'Au3Check.exe' },
            @{ Name = 'Aut2Exe\Aut2exe.exe (compiler)'; Path = 'Aut2Exe\Aut2exe.exe' },
            @{ Name = 'Aut2Exe\Aut2exe_x64.exe'; Path = 'Aut2Exe\Aut2exe_x64.exe' },
            @{ Name = 'Aut2Exe\upx.exe'; Path = 'Aut2Exe\upx.exe' },
            @{ Name = 'AutoIt.chm (help)'; Path = 'AutoIt.chm' },
            @{ Name = 'AutoItX\AutoItX3.dll'; Path = 'AutoItX\AutoItX3.dll' }
        )) {
        $full = Join-Path $autoItHome $tool.Path
        if (Test-Path -LiteralPath $full -PathType Leaf) {
            $version = ''
            try { $version = (Get-Item -LiteralPath $full).VersionInfo.FileVersion } catch { $version = '' }
            Add-Row $tool.Name 'OK' ("{0}  {1}" -f $version, $full)
        } else {
            Add-Row $tool.Name 'BAD' "missing: $full"
        }
    }

    $includeDir = Join-Path $autoItHome 'Include'
    if (Test-Path -LiteralPath $includeDir) {
        $count = @(Get-ChildItem -LiteralPath $includeDir -Filter '*.au3' -File).Count
        Add-Row 'UDF Include folder' 'OK' "$count .au3 files in $includeDir"
    } else {
        Add-Row 'UDF Include folder' 'BAD' "missing: $includeDir"
    }

    $examples = Join-Path $autoItHome 'Examples'
    if (Test-Path -LiteralPath $examples) {
        $count = @(Get-ChildItem -LiteralPath $examples -Filter '*.au3' -File -Recurse).Count
        Add-Row 'Examples' 'INFO' "$count sample scripts in $examples"
    }

    # ------------------------------------------------------------ SciTE editor
    $scite = Join-Path $autoItHome 'SciTE\SciTE.exe'
    if (Test-Path -LiteralPath $scite) {
        $missing = @()
        foreach ($f in @('SciTEGlobal.properties', 'au3.properties', 'LexAU3.dll')) {
            if (-not (Test-Path -LiteralPath (Join-Path (Join-Path $autoItHome 'SciTE') $f))) { $missing += $f }
        }
        if ($missing.Count -gt 0) {
            Add-Row 'SciTE integration' 'WARN' ("SciTE.exe present but AutoIt support files are missing: {0}" -f ($missing -join ', '))
        } else {
            Add-Row 'SciTE integration' 'OK' $scite
        }
    } else {
        Add-Row 'SciTE editor' 'INFO' 'SciTE is not installed'
    }
}

# ------------------------------------------------------------------------ PATH
$userPath = (Get-ItemProperty -Path 'HKCU:\Environment' -Name Path -ErrorAction SilentlyContinue).Path
if ([string]::IsNullOrEmpty($userPath)) { $userPath = '' }
$userEntries = @($userPath -split ';' | Where-Object { -not [string]::IsNullOrWhiteSpace($_) })

if ($autoItHome) {
    $wanted = @($autoItHome, (Join-Path $autoItHome 'Aut2Exe'), (Join-Path $autoItHome 'SciTE'))
    $missingPath = @($wanted | Where-Object { $userEntries -notcontains $_ })
    if ($missingPath.Count -eq 0) {
        Add-Row 'User PATH' 'OK' 'AutoIt3 tool folders are on the user PATH'
    } else {
        Add-Row 'User PATH' 'WARN' ("not on user PATH: {0}" -f ($missingPath -join '; '))
    }
}
$binDir = Join-Path (Get-WorkspaceRoot) 'tools\bin'
if ($userEntries -contains $binDir) {
    Add-Row 'Workspace shims' 'OK' "$binDir is on the user PATH"
} else {
    Add-Row 'Workspace shims' 'INFO' "add $binDir to the user PATH for the au3/au3check/au3build shims"
}

# --------------------------------------------------------------- file assoc
$hkcrAu3 = Get-RegDefaultValue 'HKLM:\SOFTWARE\Classes\.au3'
$hkcuAu3 = Get-RegDefaultValue 'HKCU:\SOFTWARE\Classes\.au3'
$effectiveProgId = $hkcuAu3
$assocSource = 'HKCU (user override)'
if ([string]::IsNullOrEmpty($effectiveProgId)) {
    $effectiveProgId = $hkcrAu3
    $assocSource = 'HKLM (machine)'
}

if ([string]::IsNullOrEmpty($effectiveProgId)) {
    Add-Row '.au3 association' 'WARN' 'no ProgID registered for .au3'
} else {
    $progKey = "HKCU:\SOFTWARE\Classes\$effectiveProgId"
    if (-not (Test-Path -LiteralPath $progKey)) { $progKey = "HKLM:\SOFTWARE\Classes\$effectiveProgId" }
    $openCmd = Get-RegDefaultValue "$progKey\Shell\open\Command"
    if ([string]::IsNullOrEmpty($openCmd)) { $openCmd = Get-RegDefaultValue "$progKey\shell\open\Command" }
    $target = Get-CommandTarget $openCmd
    if ([string]::IsNullOrEmpty($target)) {
        Add-Row '.au3 association' 'BAD' "ProgID '$effectiveProgId' ($assocSource) has no open command"
    } elseif (Test-CommandTargetExists $target) {
        Add-Row '.au3 association' 'OK' "$effectiveProgId ($assocSource) -> $target"
    } else {
        Add-Row '.au3 association' 'BAD' "open handler does not exist: $target  (run tools\setup-user-env.ps1)"
    }

    foreach ($verb in @('RunX86', 'RunX64', 'Compile', 'CompileX64', 'SyntaxCheck', 'Edit', '0penX86', '0penX64')) {
        $cmd = Get-RegDefaultValue "$progKey\Shell\$verb\Command"
        if ($cmd) {
            $verbTarget = Get-CommandTarget $cmd
            if (Test-CommandTargetExists $verbTarget) {
                Add-Row "verb $verb" 'OK' $cmd
            } else {
                Add-Row "verb $verb" 'BAD' "stale target: $cmd"
            }
        }
    }

    # Machine-level leftovers from an install that no longer exists. They are
    # shadowed by the per-user override above, so they are informational only -
    # repairing them would require administrator rights.
    $machineProgKey = "HKLM:\SOFTWARE\Classes\$effectiveProgId"
    if (Test-Path -LiteralPath $machineProgKey) {
        $machineOpen = Get-RegDefaultValue "$machineProgKey\Shell\open\Command"
        $machineTarget = Get-CommandTarget $machineOpen
        if ($machineTarget -and -not (Test-CommandTargetExists $machineTarget)) {
            Add-Row 'HKLM leftovers' 'INFO' ("machine-wide handlers still point at a removed install ({0}); the HKCU override wins, repairing HKLM needs admin" -f $machineTarget)
        }
    }
}

# ------------------------------------------------------------ user include dir
$userInclude = Get-UserIncludeDir
if ([string]::IsNullOrEmpty($userInclude)) {
    Add-Row 'User include folder' 'INFO' 'not registered in HKCU\SOFTWARE\AutoIt v3\AutoIt\Include'
} elseif (Test-Path -LiteralPath $userInclude) {
    Add-Row 'User include folder' 'OK' $userInclude
} else {
    Add-Row 'User include folder' 'WARN' "registered but missing on disk: $userInclude"
}

# --------------------------------------------------------------------- editors
$editors = @()
foreach ($candidate in @(
        'D:\Java\Microsoft VS Code\Code.exe',
        'C:\Program Files\Microsoft VS Code\Code.exe',
        "${env:ProgramFiles}\Microsoft VS Code\Code.exe",
        'C:\Program Files\cursor\Cursor.exe'
    )) {
    if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { $editors += $candidate }
}
foreach ($cmdName in @('code', 'cursor')) {
    $c = Get-Command $cmdName -ErrorAction SilentlyContinue
    if ($c) { $editors += $c.Source }
}
if ($editors.Count -gt 0) {
    Add-Row 'Editors' 'OK' (@($editors | Select-Object -Unique) -join '; ')
} else {
    Add-Row 'Editors' 'INFO' 'no VS Code compatible editor detected'
}

# ------------------------------------------------------------------- workspace
foreach ($folder in @('src', 'tools', 'build', 'out')) {
    $p = Join-Path (Get-WorkspaceRoot) $folder
    if (Test-Path -LiteralPath $p) {
        Add-Row "workspace\$folder" 'OK' $p
    } else {
        Add-Row "workspace\$folder" 'INFO' "not created yet: $p"
    }
}

# ---------------------------------------------------------------------- report
Write-Host ''
$rows | Format-Table -AutoSize -Wrap

Write-Host ''
Write-Host ("Summary: {0} critical, {1} warning(s)" -f $problems, $warnings)
$rows | Where-Object { $_.Level -eq 'BAD' } | ForEach-Object { Write-Host ("  [BAD ] {0}: {1}" -f $_.Area, $_.Detail) }
$rows | Where-Object { $_.Level -eq 'WARN' } | ForEach-Object { Write-Host ("  [WARN] {0}: {1}" -f $_.Area, $_.Detail) }

if ($problems -gt 0) { exit 2 }
if ($warnings -gt 0) { exit 1 }
exit 0
