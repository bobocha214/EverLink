<#
.SYNOPSIS
    Package the Flutter Windows release build into a portable .zip.

.DESCRIPTION
    Zips the contents of build\windows\x64\runner\Release into
    EverLink-{version}-windows-x64-portable.zip. Used by the CI release workflow and
    locally after `flutter build windows --release`.

.PARAMETER Version
    App version (x.y.z). Auto-read from pubspec.yaml when omitted.

.PARAMETER OutputDir
    Directory to write the zip into (defaults to current directory).
#>
param(
  [string]$Version,
  [string]$OutputDir = "."
)

$ErrorActionPreference = "Stop"

if (-not $Version) {
  $m = Select-String -Path "pubspec.yaml" -Pattern '^version:\s*(\d+\.\d+\.\d+)'
  if ($m) { $Version = $m.Matches.Groups[1].Value }
  if (-not $Version) { Write-Error "Cannot determine version from pubspec.yaml"; exit 1 }
}

$src = Join-Path $PWD "build\windows\x64\runner\Release"
if (-not (Test-Path $src)) {
  Write-Error "Release build not found at '$src'. Run 'flutter build windows --release' first."
  exit 1
}

if (-not (Test-Path $OutputDir)) { New-Item -ItemType Directory -Path $OutputDir | Out-Null }
$zip = Join-Path $OutputDir "EverLink-$Version-windows-x64-portable.zip"
if (Test-Path $zip) { Remove-Item $zip -Force }

Compress-Archive -Path (Join-Path $src '*') -DestinationPath $zip -Force
Write-Host "Created portable package: $zip"
