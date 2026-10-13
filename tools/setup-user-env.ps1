<#
.SYNOPSIS
    Prepares the per-user AutoIt3 environment (no administrator rights needed).

.DESCRIPTION
    Every change is written under HKEY_CURRENT_USER, so nothing outside the user
    profile is touched and System Restore / a reinstall of AutoIt is not affected.

    1. Adds the AutoIt3 tool folders (and this workspace's tools\bin shims) to the
       user PATH.
    2. Registers a working .au3 file association that overrides the broken
       machine-wide one (it points at a deleted install):
         open / Edit -> the configured editor
         Run Script (x86) / Run Script (x64) -> AutoIt3.exe / AutoIt3_x64.exe
         Compile Script -> Aut2exe.exe
         Syntax Check -> Au3Check.exe in a kept-open console
    3. Registers the user include folder used by AutoIt's #include <...> search.
    4. Repoints stale Aut2Exe dialog folders at the current install.

    Run it again at any time; it is idempotent.

.EXAMPLE
    .\tools\setup-user-env.ps1 -DryRun

.EXAMPLE
    .\tools\setup-user-env.ps1 -Editor 'D:\Java\Microsoft VS Code\Code.exe'
#>
[CmdletBinding()]
param(
    # Editor used for "open" / "Edit". Auto-detected when omitted.
    [string]$Editor,

    # User include folder. Default: <Documents>\AutoIt3\UserInclude
    [string]$IncludeDir,

    [switch]$SkipPath,
    [switch]$SkipAssociation,
    [switch]$SkipIncludeDir,

    # Show what would change without writing anything.
    [switch]$DryRun
)

. "$PSScriptRoot\_common.ps1"

$autoItHome = Get-AutoItHome
$workspaceRoot = Get-WorkspaceRoot
$binDir = Join-Path $workspaceRoot 'tools\bin'
$changed = 0

function Write-Action {
    param([string]$Message)
    Write-Host ("  {0}" -f $Message)
    $script:changed++
}

function Set-RegString {
    param(
        [Parameter(Mandatory = $true)][string]$Key,
        [string]$Name = '',
        [Parameter(Mandatory = $true)][string]$Value
    )

    $label = $Key
    if ($Name) { $label = $Key + ' :: ' + $Name }

    if ($DryRun) {
        Write-Action ("[dry-run] {0} = {1}" -f $label, $Value)
        return
    }

    if (-not (Test-Path -LiteralPath $Key)) { [void](New-Item -Path $Key -Force) }
    if ($Name -eq '') {
        Set-Item -LiteralPath $Key -Value $Value
    } else {
        [void](New-ItemProperty -Path $Key -Name $Name -Value $Value -PropertyType String -Force)
    }
    Write-Action ("{0} = {1}" -f $label, $Value)
}

function Send-EnvironmentChanged {
    try {
        if (-not ('Win32.EnvNotify' -as [type])) {
            Add-Type -Namespace Win32 -Name EnvNotify -MemberDefinition @'
[System.Runtime.InteropServices.DllImport("user32.dll", SetLastError = true, CharSet = System.Runtime.InteropServices.CharSet.Auto)]
public static extern System.IntPtr SendMessageTimeout(System.IntPtr hWnd, uint Msg, System.UIntPtr wParam, string lParam, uint fuFlags, uint uTimeout, out System.UIntPtr lpdwResult);
'@
        }
        $result = [UIntPtr]::Zero
        [void][Win32.EnvNotify]::SendMessageTimeout([IntPtr]0xffff, 0x1A, [UIntPtr]::Zero, 'Environment', 2, 5000, [ref]$result)
        Write-Host '  (broadcast WM_SETTINGCHANGE so new processes see the updated PATH)'
    } catch {
        Write-Host '  (could not broadcast the environment change; new processes pick it up anyway)'
    }
}

Write-Section 'AutoIt3 per-user environment setup'
Write-Host "Install    : $autoItHome"
Write-Host "Workspace  : $workspaceRoot"
if ($DryRun) { Write-Host 'Mode       : DRY RUN (nothing will be written)' }

# ------------------------------------------------------------------------ PATH
if (-not $SkipPath) {
    Write-Host ''
    Write-Host '[1] User PATH'
    $key = 'HKCU:\Environment'
    $current = (Get-ItemProperty -Path $key -Name Path -ErrorAction SilentlyContinue).Path
    if ([string]::IsNullOrEmpty($current)) { $current = '' }
    $entries = New-Object System.Collections.Generic.List[string]
    foreach ($e in ($current -split ';')) {
        if (-not [string]::IsNullOrWhiteSpace($e)) { $entries.Add($e.TrimEnd('\')) }
    }

    $wanted = @($autoItHome, (Join-Path $autoItHome 'Aut2Exe'), (Join-Path $autoItHome 'SciTE'), $binDir)
    $added = @()
    foreach ($w in $wanted) {
        if (-not ($entries -contains $w.TrimEnd('\'))) {
            $entries.Add($w.TrimEnd('\'))
            $added += $w
        }
    }

    if ($added.Count -eq 0) {
        Write-Host '  already up to date'
    } else {
        if ($DryRun) {
            Write-Action ("[dry-run] HKCU:\Environment :: Path += {0}" -f ($added -join '; '))
        } else {
            [void](New-ItemProperty -Path $key -Name Path -Value ($entries -join ';') -PropertyType ExpandString -Force)
            Write-Action ("HKCU:\Environment :: Path += {0}" -f ($added -join '; '))
            Send-EnvironmentChanged
        }
    }
}

# ----------------------------------------------------------------- association
if (-not $SkipAssociation) {
    Write-Host ''
    Write-Host '[2] .au3 file association (HKCU\Software\Classes)'

    if (-not $Editor) {
        foreach ($candidate in @(
                $env:AUTOIT_EDITOR,
                'D:\Java\Microsoft VS Code\Code.exe',
                "${env:ProgramFiles}\Microsoft VS Code\Code.exe",
                'C:\Program Files\Microsoft VS Code\Code.exe',
                'C:\Program Files\cursor\Cursor.exe',
                (Join-Path $autoItHome 'SciTE\SciTE.exe')
            )) {
            if ($candidate -and (Test-Path -LiteralPath $candidate -PathType Leaf)) { $Editor = $candidate; break }
        }
    }
    if (-not $Editor) {
        Write-Host '  WARNING: no editor found; "open" will fall back to the interpreter.'
        $Editor = Join-Path $autoItHome 'AutoIt3.exe'
    }
    Write-Host "  editor for 'open'/'Edit': $Editor"

    $progId = 'AutoIt3Script'
    $icon = ''
    foreach ($iconName in @('filetype1.ico', 'AutoIt_Main_v10_48x48_256.ico', 'AutoIt_Main_v9_48x48_256.ico')) {
        $candidate = Join-Path $autoItHome ('Aut2Exe\Icons\' + $iconName)
        if (Test-Path -LiteralPath $candidate -PathType Leaf) { $icon = $candidate; break }
    }
    if (-not $icon) { $icon = Join-Path $autoItHome 'AutoIt3.exe' }

    $base = "HKCU:\Software\Classes"
    Set-RegString -Key "$base\.au3" -Value $progId
    Set-RegString -Key "$base\$progId" -Value 'AutoIt v3 Script'
    Set-RegString -Key "$base\$progId\DefaultIcon" -Value $icon
    Set-RegString -Key "$base\$progId\Shell\open" -Value '&Edit Script'
    Set-RegString -Key "$base\$progId\Shell\open\Command" -Value ((Format-Arg $Editor) + ' "%1"')

    Set-RegString -Key "$base\$progId\Shell\Edit" -Value 'Edit Script'
    Set-RegString -Key "$base\$progId\Shell\Edit\Command" -Value ((Format-Arg $Editor) + ' "%1"')

    Set-RegString -Key "$base\$progId\Shell\RunX86" -Value 'Run Script (x86)'
    Set-RegString -Key "$base\$progId\Shell\RunX86\Command" -Value ((Format-Arg (Join-Path $autoItHome 'AutoIt3.exe')) + ' "%1" %*')

    Set-RegString -Key "$base\$progId\Shell\RunX64" -Value 'Run Script (x64)'
    Set-RegString -Key "$base\$progId\Shell\RunX64\Command" -Value ((Format-Arg (Join-Path $autoItHome 'AutoIt3_x64.exe')) + ' "%1" %*')

    Set-RegString -Key "$base\$progId\Shell\Compile" -Value 'Compile Script (same folder)'
    Set-RegString -Key "$base\$progId\Shell\Compile\Command" -Value ((Format-Arg (Join-Path $autoItHome 'Aut2Exe\Aut2exe.exe')) + ' /in "%1"')

    Set-RegString -Key "$base\$progId\Shell\SyntaxCheck" -Value 'Syntax Check'
    Set-RegString -Key "$base\$progId\Shell\SyntaxCheck\Command" -Value ('cmd.exe /k ""' + (Join-Path $autoItHome 'Au3Check.exe') + '" "%1""')
}

# ------------------------------------------------------------ user include dir
if (-not $SkipIncludeDir) {
    Write-Host ''
    Write-Host '[3] User include folder'
    if (-not $IncludeDir) {
        $documents = [Environment]::GetFolderPath('MyDocuments')
        $IncludeDir = Join-Path $documents 'AutoIt3\UserInclude'
    }

    if (Test-Path -LiteralPath $IncludeDir) {
        Write-Host "  exists: $IncludeDir"
    } elseif ($DryRun) {
        Write-Action "[dry-run] create folder $IncludeDir"
    } else {
        try {
            [void](New-Item -ItemType Directory -Path $IncludeDir -Force)
            Write-Action "created folder $IncludeDir"
        } catch {
            Write-Host "  WARNING: could not create $IncludeDir"
            Write-Host "           $($_.Exception.Message)"
        }
    }
    Set-RegString -Key 'HKCU:\SOFTWARE\AutoIt v3\AutoIt' -Name 'Include' -Value $IncludeDir
}

# ------------------------------------------------------------ Aut2Exe leftovers
Write-Host ''
Write-Host '[4] Aut2Exe dialog defaults'
$iconsDir = Join-Path $autoItHome 'Aut2Exe\Icons'
if (Test-Path -LiteralPath $iconsDir) {
    Set-RegString -Key 'HKCU:\SOFTWARE\AutoIt v3\Aut2Exe' -Name 'LastIconDir' -Value $iconsDir
}

Write-Host ''
Write-Host ("Done. {0} change(s)." -f $changed)
if (-not $DryRun -and $changed -gt 0) {
    Write-Host 'Open a NEW terminal (and restart any running editor) so the updated PATH is picked up.'
}
Write-Host 'Verify with:  .\tools\env-doctor.ps1'
exit 0
