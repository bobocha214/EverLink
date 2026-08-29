<#
.SYNOPSIS
    One-click local build of the EverLink Windows installer + portable zip.

.DESCRIPTION
    1) flutter pub get
    2) flutter build windows --release
    3) compile installer via Inno Setup 6 (ISCC.exe)
    4) package the portable zip
    Outputs land in build\windows\installer\.

.PARAMETER Version
    App version (x.y.z). Auto-read from pubspec.yaml when omitted.
#>
param([string]$Version)

$ErrorActionPreference = "Stop"
$root = (Split-Path -Parent $PSScriptRoot)
Push-Location $root
try {
  flutter pub get
  flutter build windows --release

  if (-not $Version) {
    $m = Select-String -Path "pubspec.yaml" -Pattern '^version:\s*(\d+\.\d+\.\d+)'
    if ($m) { $Version = $m.Matches.Groups[1].Value }
  }
  if (-not $Version) { Write-Error "Cannot determine version"; exit 1 }

  # Build the installer. Requires Inno Setup 6; adjust path if installed elsewhere.
  $iscc = "C:\Program Files (x86)\Inno Setup 6\ISCC.exe"
  if (-not (Test-Path $iscc)) { $iscc = "C:\Program Files\Inno Setup 6\ISCC.exe" }
  if (-not (Test-Path $iscc)) {
    Write-Warning "Inno Setup not found at '$iscc'. Skipping installer. Install from https://jrsoftware.org/isinfo.php"
  } else {
    & $iscc "windows\installer.iss" "/DMyAppVersion=$Version" "/Obuild\windows\installer"
    if ($LASTEXITCODE -ne 0) { Write-Error "iscc failed (exit $LASTEXITCODE)"; exit 1 }
  }

  pwsh -NoProfile -ExecutionPolicy Bypass -File (Join-Path $PSScriptRoot "package_windows.ps1") `
    -Version $Version -OutputDir "build\windows\installer"
} finally {
  Pop-Location
}
