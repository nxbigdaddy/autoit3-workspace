<#
.SYNOPSIS
    Reports (and optionally fixes) the text encoding of AutoIt .au3 source files.

.DESCRIPTION
    AutoIt3 3.3.18 reads script files by auto-detection: UTF-8 with BOM, UTF-16
    with BOM, UTF-8 without BOM (when the bytes are valid UTF-8) and otherwise the
    system ANSI code page. All of those work on this machine.

    The risk is ambiguity, not breakage: a BOM-less file is only decoded correctly
    while the auto-detection guesses right, which depends on the code page of the
    machine that runs or compiles it. Adding a UTF-8 BOM makes the encoding
    explicit and portable.

    This script lists .au3 files that contain non-ASCII bytes but no BOM, and with
    -Fix it prepends the UTF-8 BOM to them.

.EXAMPLE
    .\tools\au3-encoding.ps1

.EXAMPLE
    .\tools\au3-encoding.ps1 -Path src -Fix
#>
[CmdletBinding()]
param(
    [string]$Path,

    # Add the UTF-8 BOM to every affected file.
    [switch]$Fix
)

. "$PSScriptRoot\_common.ps1"

if (-not $Path) { $Path = Join-Path (Get-WorkspaceRoot) 'src' }
$full = Resolve-FullPath -Path $Path
if (-not (Test-Path -LiteralPath $full)) { throw "Path not found: $full" }

$files = @()
if (Test-Path -LiteralPath $full -PathType Leaf) {
    $files = @(Get-Item -LiteralPath $full)
} else {
    $files = @(Get-ChildItem -LiteralPath $full -Filter '*.au3' -File -Recurse)
}

$bom = [byte[]](0xEF, 0xBB, 0xBF)
$flagged = 0
$fixed = 0

Write-Host "Scanning $($files.Count) file(s) under $full"
Write-Host ''

foreach ($file in $files) {
    $bytes = [System.IO.File]::ReadAllBytes($file.FullName)
    $hasBom = ($bytes.Length -ge 3 -and $bytes[0] -eq $bom[0] -and $bytes[1] -eq $bom[1] -and $bytes[2] -eq $bom[2])
    $hasNonAscii = $false
    for ($i = 0; $i -lt $bytes.Length; $i++) {
        if ($bytes[$i] -gt 0x7F) { $hasNonAscii = $true; break }
    }

    if ($hasBom) {
        Write-Host ("  [BOM   ] {0}" -f $file.FullName)
    } elseif ($hasNonAscii) {
        $flagged++
        if ($Fix) {
            $out = New-Object byte[] ($bytes.Length + 3)
            [Array]::Copy($bom, 0, $out, 0, 3)
            [Array]::Copy($bytes, 0, $out, 3, $bytes.Length)
            [System.IO.File]::WriteAllBytes($file.FullName, $out)
            $fixed++
            Write-Host ("  [FIXED ] {0}  (UTF-8 BOM added)" -f $file.FullName)
        } else {
            Write-Host ("  [NOBOM ] {0}  (non-ASCII without BOM - decoding relies on auto-detection; -Fix normalises it)" -f $file.FullName)
        }
    } else {
        Write-Host ("  [ASCII ] {0}" -f $file.FullName)
    }
}

Write-Host ''
if ($flagged -eq 0) {
    Write-Host 'All .au3 files are either pure ASCII or carry a UTF-8 BOM.'
    exit 0
}
if ($Fix) {
    Write-Host "$fixed file(s) normalised to UTF-8 with BOM."
    exit 0
}
Write-Host "$flagged file(s) contain non-ASCII text without a BOM (encoding is ambiguous)."
exit 1
