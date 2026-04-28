[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir
$zigWrapper = Join-Path $scriptDir "zigw.ps1"
$exePath = Join-Path $rootDir "zig-out\bin\VAR1.exe"

Push-Location $rootDir
try {
  & $zigWrapper build -Dtarget=x86_64-windows-gnu --summary all
  if ($LASTEXITCODE -ne 0) {
    exit $LASTEXITCODE
  }

  & $exePath health
  exit $LASTEXITCODE
} finally {
  Pop-Location
}
