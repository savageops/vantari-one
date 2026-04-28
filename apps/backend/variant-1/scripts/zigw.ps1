[CmdletBinding()]
param(
  [Parameter(ValueFromRemainingArguments = $true)]
  [string[]]$ZigArgs
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
Add-Type -AssemblyName System.IO.Compression
Add-Type -AssemblyName System.IO.Compression.FileSystem

$zigVersion = "0.15.1"
$toolchainRoot = Join-Path $env:LOCALAPPDATA "VANTARI-ONE\toolchains"
$installDir = Join-Path $toolchainRoot "zig-x86_64-windows-$zigVersion"
$zigExe = Join-Path $installDir "zig.exe"
$bundledArchive = Join-Path (Split-Path -Parent $MyInvocation.MyCommand.Path) "..\.toolchain\zig-x86_64-windows-$zigVersion.zip"
$downloadUrl = "https://ziglang.org/download/$zigVersion/zig-x86_64-windows-$zigVersion.zip"

function Test-ZigArchive {
  param(
    [Parameter(Mandatory = $true)]
    [string]$Path
  )

  if (-not (Test-Path -LiteralPath $Path)) {
    return $false
  }

  $stream = $null
  $archive = $null
  try {
    $stream = [System.IO.File]::Open($Path, [System.IO.FileMode]::Open, [System.IO.FileAccess]::Read, [System.IO.FileShare]::Read)
    $archive = New-Object System.IO.Compression.ZipArchive($stream, [System.IO.Compression.ZipArchiveMode]::Read, $false)
    $null = $archive.Entries.Count
    return $true
  } catch {
    return $false
  } finally {
    if ($archive -ne $null) {
      $archive.Dispose()
    }
    if ($stream -ne $null) {
      $stream.Dispose()
    }
  }
}

function Install-ZigToolchain {
  New-Item -ItemType Directory -Force -Path $toolchainRoot | Out-Null

  $archivePath = Join-Path $toolchainRoot "zig-x86_64-windows-$zigVersion.zip"
  $extractDir = Join-Path $toolchainRoot "_extract-zig-$zigVersion"
  $expandedDir = Join-Path $extractDir "zig-x86_64-windows-$zigVersion"
  $expandedExe = Join-Path $expandedDir "zig.exe"

  if ((Test-Path -LiteralPath $extractDir) -and -not (Test-Path -LiteralPath $expandedExe)) {
    Remove-Item -LiteralPath $extractDir -Recurse -Force
  }

  if ((Test-Path -LiteralPath $archivePath) -and -not (Test-ZigArchive -Path $archivePath)) {
    Remove-Item -LiteralPath $archivePath -Force
  }

  if (Test-Path -LiteralPath $bundledArchive) {
    Copy-Item -LiteralPath $bundledArchive -Destination $archivePath -Force
  } elseif (-not (Test-Path -LiteralPath $archivePath)) {
    Invoke-WebRequest -Uri $downloadUrl -OutFile $archivePath
  }

  if (-not (Test-ZigArchive -Path $archivePath)) {
    if (Test-Path -LiteralPath $archivePath) {
      Remove-Item -LiteralPath $archivePath -Force
    }
    throw "zig archive is invalid or truncated: $archivePath"
  }

  if (-not (Test-Path -LiteralPath $expandedExe)) {
    Expand-Archive -LiteralPath $archivePath -DestinationPath $extractDir -Force
  }

  if (-not (Test-Path -LiteralPath $expandedDir)) {
    throw "zig archive extracted without the expected directory: $expandedDir"
  }

  if (Test-Path -LiteralPath $installDir) {
    Remove-Item -LiteralPath $installDir -Recurse -Force
  }

  Move-Item -LiteralPath $expandedDir -Destination $installDir
  Remove-Item -LiteralPath $extractDir -Recurse -Force
}

if (-not (Test-Path -LiteralPath $zigExe)) {
  Install-ZigToolchain
}

$env:ZIG_LOCAL_CACHE_DIR = Join-Path $env:TEMP "VANTARI-ONE-VAR1-local-cache"
$env:ZIG_GLOBAL_CACHE_DIR = Join-Path $env:TEMP "VANTARI-ONE-VAR1-global-cache"
New-Item -ItemType Directory -Force -Path $env:ZIG_LOCAL_CACHE_DIR, $env:ZIG_GLOBAL_CACHE_DIR | Out-Null

& $zigExe @ZigArgs
exit $LASTEXITCODE
