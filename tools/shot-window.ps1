<#
.SYNOPSIS
    Launches a GUI, captures ONLY its own window rectangle to a PNG, then closes it.

.DESCRIPTION
    Used to actually look at a layout instead of guessing. It captures just the
    window (not the whole desktop), so nothing else on screen ends up in the file.

.EXAMPLE
    .\tools\shot-window.ps1 -ProcessPath build\AicConsole.exe -Arguments '/demogui' -TitleLike 'aic 控制台' -OutFile out\ui-aic.png
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$ProcessPath,
    [string]$Arguments = '',
    [Parameter(Mandatory = $true)][string]$TitleLike,
    [Parameter(Mandatory = $true)][string]$OutFile,
    [int]$WaitSeconds = 6
)

$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

if (-not ('Win32Rect' -as [type])) {
    Add-Type -Namespace '' -Name Win32Rect -MemberDefinition @'
[StructLayout(LayoutKind.Sequential)]
public struct RECT { public int Left; public int Top; public int Right; public int Bottom; }

[DllImport("user32.dll", SetLastError = true)]
public static extern bool GetWindowRect(System.IntPtr hWnd, out RECT r);

[DllImport("user32.dll")]
public static extern bool SetForegroundWindow(System.IntPtr hWnd);

[DllImport("user32.dll")]
public static extern bool IsWindowVisible(System.IntPtr hWnd);
'@
}

$full = (Resolve-Path -LiteralPath $ProcessPath).Path
$fullOut = [System.IO.Path]::GetFullPath((Join-Path (Get-Location).Path $OutFile))

$psi = New-Object System.Diagnostics.ProcessStartInfo
$psi.FileName = $full
$psi.Arguments = $Arguments
$psi.UseShellExecute = $false
$proc = [System.Diagnostics.Process]::Start($psi)

try {
    # wait for a visible window whose title matches
    $handle = [IntPtr]::Zero
    for ($i = 0; $i -lt ($WaitSeconds * 4); $i++) {
        Start-Sleep -Milliseconds 250
        $proc.Refresh()
        if ($proc.HasExited) { throw "process exited before showing a window (exit $($proc.ExitCode))" }
        if ($proc.MainWindowHandle -ne [IntPtr]::Zero) {
            $t = $proc.MainWindowTitle
            if ($t -and $t -like "*$TitleLike*" -and [Win32Rect]::IsWindowVisible($proc.MainWindowHandle)) {
                $handle = $proc.MainWindowHandle
                break
            }
        }
    }
    if ($handle -eq [IntPtr]::Zero) { throw "no visible window matching '$TitleLike' after $WaitSeconds s" }

    # let it finish its first paint / data fill
    Start-Sleep -Seconds 3
    [void][Win32Rect]::SetForegroundWindow($handle)
    Start-Sleep -Milliseconds 600

    $rect = New-Object Win32Rect+RECT
    if (-not [Win32Rect]::GetWindowRect($handle, [ref]$rect)) { throw 'GetWindowRect failed' }
    $w = $rect.Right - $rect.Left
    $h = $rect.Bottom - $rect.Top
    if ($w -le 0 -or $h -le 0) { throw "bad window rect ${w}x${h}" }

    $bmp = New-Object System.Drawing.Bitmap($w, $h)
    $gfx = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $gfx.CopyFromScreen($rect.Left, $rect.Top, 0, 0, (New-Object System.Drawing.Size($w, $h)))
    } finally {
        $gfx.Dispose()
    }

    $dir = Split-Path -Parent $fullOut
    if ($dir -and -not (Test-Path -LiteralPath $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    $bmp.Save($fullOut, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()

    Write-Host ("captured {0}x{1} -> {2}" -f $w, $h, $fullOut)
} finally {
    if (-not $proc.HasExited) {
        try { $proc.Kill(); $proc.WaitForExit() } catch { }
    }
}
