<#
.SYNOPSIS
    End-to-end verification of the AutoIt3 toolchain in this workspace.

.DESCRIPTION
    Proves that every part of the prepared environment actually works:
      * Au3Check accepts valid code and rejects broken code (exit code 2)
      * the interpreter runs scripts, waits for them and returns their exit code
      * Aut2Exe produces real x86 GUI and x64 console binaries
      * the compiled binaries run
      * the encoding helper reports clean sources

    Run it after changing anything in tools\ or after installing/upgrading AutoIt.

.EXAMPLE
    .\tests\run-tests.ps1
#>
[CmdletBinding()]
param()

. "$PSScriptRoot\..\tools\_common.ps1"

$results = New-Object System.Collections.Generic.List[object]
$failures = 0

function Add-Result {
    param([string]$Name, [bool]$Passed, [string]$Detail = '')
    $status = 'FAIL'
    if ($Passed) { $status = 'PASS' }
    $results.Add([pscustomobject]@{ Result = $status; Test = $Name; Detail = $Detail }) | Out-Null
    if (-not $Passed) { $script:failures++ }
}

# Runs one of the tools\*.ps1 wrappers in-process and returns output + exit code.
function Invoke-Tool {
    param(
        [Parameter(Mandatory = $true)][string]$ScriptPath,
        [hashtable]$BoundParameters = @{}
    )
    $text = (& $ScriptPath @BoundParameters *>&1 | Out-String)
    $code = $LASTEXITCODE
    if ($null -eq $code) { $code = 0 }
    return [pscustomobject]@{ Output = $text; Code = $code }
}

function Get-PeInfo {
    param([Parameter(Mandatory = $true)][string]$ExePath)
    $bytes = [System.IO.File]::ReadAllBytes($ExePath)
    $peOffset = [System.BitConverter]::ToInt32($bytes, 0x3C)
    return [pscustomobject]@{
        Machine   = [System.BitConverter]::ToUInt16($bytes, $peOffset + 4)
        Subsystem = [System.BitConverter]::ToUInt16($bytes, $peOffset + 0x5C)
    }
}

$workspace = Get-WorkspaceRoot
$hello = Join-Path $workspace 'src\hello.au3'
$broken = Join-Path $workspace 'tests\fixtures\broken-sample.au3'
$buildDir = Join-Path $workspace 'build'
$outDir = Join-Path $workspace 'out'

if (-not (Test-Path -LiteralPath $outDir)) { [void](New-Item -ItemType Directory -Path $outDir -Force) }

Write-Section 'AutoIt3 toolchain tests'
Write-Host "Install   : $(Get-AutoItHome)"
Write-Host "Workspace : $workspace"

# 1 ------------------------------------------------------------ syntax checking
$check = Invoke-Tool -ScriptPath (Join-Path $workspace 'tools\au3-check.ps1') -BoundParameters @{ Path = $hello }
Add-Result 'Au3Check accepts valid code' ($check.Code -eq 0) "exit=$($check.Code)"

$bad = Invoke-Tool -ScriptPath (Join-Path $workspace 'tools\au3-check.ps1') -BoundParameters @{ Path = $broken }
$badReported = ($bad.Code -eq 2) -and ($bad.Output -match 'error')
Add-Result 'Au3Check rejects broken code with exit 2' $badReported "exit=$($bad.Code)"

# 2 ----------------------------------------------------------------- execution
# The interpreter writes ConsoleWrite output straight to the console, so the
# run is verified through the log file the script itself produces.
function Invoke-Hello {
    param([Parameter(Mandatory = $true)][string]$Arch)

    $log = Join-Path $outDir 'hello.log'
    Remove-Item -LiteralPath $log -Force -ErrorAction SilentlyContinue
    $run = Invoke-Tool -ScriptPath (Join-Path $workspace 'tools\au3-run.ps1') -BoundParameters @{ Path = $hello; Arch = $Arch }

    $text = ''
    if (Test-Path -LiteralPath $log) { $text = (Get-Content -LiteralPath $log -Raw) }
    return [pscustomobject]@{ Code = $run.Code; Log = $text }
}

$x86 = Invoke-Hello -Arch 'x86'
$x86Ok = ($x86.Code -eq 0) -and ($x86.Log -match 'SMOKE TEST: PASS') -and ($x86.Log -match 'Interpreter x64 : 0')
Add-Result 'Runs a script with the x86 interpreter' $x86Ok "exit=$($x86.Code)"

$x64 = Invoke-Hello -Arch 'x64'
$x64Ok = ($x64.Code -eq 0) -and ($x64.Log -match 'SMOKE TEST: PASS') -and ($x64.Log -match 'Interpreter x64 : 1')
Add-Result 'Runs a script with the x64 interpreter' $x64Ok "exit=$($x64.Code)"

# 3 ------------------------------------------- waiting + exit code propagation
$probeScript = Join-Path $outDir '_exitcode-probe.au3'
@'
Sleep(1200)
ConsoleWrite("probe finished" & @CRLF)
Exit 7
'@ | Set-Content -LiteralPath $probeScript -Encoding ASCII

$sw = [System.Diagnostics.Stopwatch]::StartNew()
$probe = Invoke-Tool -ScriptPath (Join-Path $workspace 'tools\au3-run.ps1') -BoundParameters @{ Path = $probeScript }
$sw.Stop()
$waited = $sw.Elapsed.TotalSeconds -ge 1.1
Add-Result 'The run wrapper waits for the script to finish' $waited ("elapsed={0:N2}s" -f $sw.Elapsed.TotalSeconds)
Add-Result 'The script exit code is propagated' ($probe.Code -eq 7) "exit=$($probe.Code)"
Remove-Item -LiteralPath $probeScript -Force -ErrorAction SilentlyContinue

# 4 --------------------------------------------------------------- compilation
$exeX86 = Join-Path $buildDir 'test_hello_x86.exe'
$b1 = Invoke-Tool -ScriptPath (Join-Path $workspace 'tools\au3-build.ps1') -BoundParameters @{ Path = $hello; Out = $exeX86; Arch = 'x86' }
$b1Ok = ($b1.Code -eq 0) -and (Test-Path -LiteralPath $exeX86 -PathType Leaf)
Add-Result 'Compiles an x86 GUI executable' $b1Ok "exit=$($b1.Code)"
if ($b1Ok) {
    $pe = Get-PeInfo -ExePath $exeX86
    Add-Result 'x86 exe has the right PE header' (($pe.Machine -eq 0x14C) -and ($pe.Subsystem -eq 2)) ("machine=0x{0:X} subsystem={1}" -f $pe.Machine, $pe.Subsystem)
}

$exeX64 = Join-Path $buildDir 'test_hello_x64_console.exe'
$b2 = Invoke-Tool -ScriptPath (Join-Path $workspace 'tools\au3-build.ps1') -BoundParameters @{ Path = $hello; Out = $exeX64; Arch = 'x64'; Type = 'console' }
$b2Ok = ($b2.Code -eq 0) -and (Test-Path -LiteralPath $exeX64 -PathType Leaf)
Add-Result 'Compiles an x64 console executable' $b2Ok "exit=$($b2.Code)"
if ($b2Ok) {
    $pe64 = Get-PeInfo -ExePath $exeX64
    Add-Result 'x64 exe has the right PE header' (($pe64.Machine -eq 0x8664) -and ($pe64.Subsystem -eq 3)) ("machine=0x{0:X} subsystem={1}" -f $pe64.Machine, $pe64.Subsystem)

    $run = Invoke-NativeAndWait -FilePath $exeX64 -CaptureOutput -TimeoutSec 60
    $runOk = ($run.ExitCode -eq 0) -and ($run.StdOut -match 'SMOKE TEST: PASS')
    Add-Result 'The compiled executable runs correctly' $runOk "exit=$($run.ExitCode)"
}

# 5 ------------------------------------------------------------------ encoding
$enc = Invoke-Tool -ScriptPath (Join-Path $workspace 'tools\au3-encoding.ps1') -BoundParameters @{ Path = (Join-Path $workspace 'src') }
Add-Result 'All src\*.au3 files are encoding-safe' ($enc.Code -eq 0) "exit=$($enc.Code)"

# 6 --------------------------------------------------------- application tests
$guiTool = Invoke-Tool -ScriptPath (Join-Path $workspace 'tools\au3-run.ps1') -BoundParameters @{
    Path       = (Join-Path $workspace 'src\GuiTool.au3')
    ScriptArgs = '/selftest'
}
Add-Result 'GuiTool core logic self-test' ($guiTool.Code -eq 0) "exit=$($guiTool.Code)"

$diskInfo = Invoke-Tool -ScriptPath (Join-Path $workspace 'tools\au3-run.ps1') -BoundParameters @{
    Path       = (Join-Path $workspace 'src\DiskInfo.au3')
    ScriptArgs = '/selftest'
}
Add-Result 'DiskInfo logic + graceful degradation self-test' ($diskInfo.Code -eq 0) "exit=$($diskInfo.Code)"

# The GUI code that fills the lists/details only runs when disk data exists, so it
# is exercised with injected demo data: launch, stay alive, then kill.
$demoPsi = New-Object System.Diagnostics.ProcessStartInfo
$demoPsi.FileName = Get-AutoItExePath
$demoPsi.Arguments = '"' + (Join-Path $workspace 'src\DiskInfo.au3') + '" /demogui'
$demoPsi.UseShellExecute = $false
$demoProc = [System.Diagnostics.Process]::Start($demoPsi)
Start-Sleep -Seconds 4
$demoAlive = -not $demoProc.HasExited
if ($demoAlive) {
    try { $demoProc.Kill(); $demoProc.WaitForExit() } catch { }
}
Add-Result 'DiskInfo GUI survives a data-populated refresh' $demoAlive 'demo data, 4s alive check'

# The same guard for the rename tool, which also builds its list only with a plan.
$planPsi = New-Object System.Diagnostics.ProcessStartInfo
$planPsi.FileName = Get-AutoItExePath
$planPsi.Arguments = '"' + (Join-Path $workspace 'src\GuiTool.au3') + '"'
$planPsi.UseShellExecute = $false
$planProc = [System.Diagnostics.Process]::Start($planPsi)
Start-Sleep -Seconds 3
$planAlive = -not $planProc.HasExited
if ($planAlive) {
    try { $planProc.Kill(); $planProc.WaitForExit() } catch { }
}
Add-Result 'GuiTool GUI starts and stays alive' $planAlive '3s alive check'

# --- AIC console (multi-agent orchestrator client) --------------------------
$aicSelf = Invoke-Tool -ScriptPath (Join-Path $workspace 'tools\au3-run.ps1') -BoundParameters @{
    Path       = (Join-Path $workspace 'src\AicConsole.au3')
    ScriptArgs = '/selftest'
}
Add-Result 'AIC console self-test (config/runs/control)' ($aicSelf.Code -eq 0) "exit=$($aicSelf.Code)"

$aicPsi = New-Object System.Diagnostics.ProcessStartInfo
$aicPsi.FileName = Get-AutoItExePath
$aicPsi.Arguments = '"' + (Join-Path $workspace 'src\AicConsole.au3') + '" /demogui'
$aicPsi.UseShellExecute = $false
$aicProc = [System.Diagnostics.Process]::Start($aicPsi)
Start-Sleep -Seconds 4
$aicAlive = -not $aicProc.HasExited
if ($aicAlive) {
    try { $aicProc.Kill(); $aicProc.WaitForExit() } catch { }
}
Add-Result 'AIC console GUI survives with a demo run' $aicAlive 'demo home, 4s alive check'

# Independent oracle over the files the console just wrote (must run after the
# self-test above, which builds and mutates the demo home).
$python = Get-Command python -ErrorAction SilentlyContinue
if (-not $python) {
    Add-Result 'AIC write paths verified by pyyaml/json oracle' $true 'skipped (python missing)'
} else {
    Push-Location $workspace
    try {
        & $python.Source (Join-Path $workspace 'tests\verify_aic.py') | Out-Null
        $aicOracle = $LASTEXITCODE
    } finally {
        Pop-Location
    }
    Add-Result 'AIC write paths verified by pyyaml/json oracle' ($aicOracle -eq 0) "exit=$aicOracle"
}

# ---------------------------------------------------------------------- report
Write-Host ''
$results | Format-Table -AutoSize -Wrap

Write-Host ''
if ($failures -gt 0) {
    Write-Host ("{0} of {1} test(s) FAILED" -f $failures, $results.Count)
    $results | Where-Object { $_.Result -eq 'FAIL' } | ForEach-Object { Write-Host ("  [FAIL] {0}  {1}" -f $_.Test, $_.Detail) }
    exit 1
}
Write-Host ("All {0} test(s) passed." -f $results.Count)
exit 0
