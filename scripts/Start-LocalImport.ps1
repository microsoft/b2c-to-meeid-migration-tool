# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
<#
.SYNOPSIS
    Simple Mode — Import phase. Reads exported blobs and creates users
    in Entra External ID.

.DESCRIPTION
    This script:
    1. Verifies Azurite is running via the VS Code extension (checks ports 10000/10001)
    2. Builds and runs the B2C Migration Kit console with the 'import' operation

    Run Start-LocalExport.ps1 first to populate Blob Storage with B2C user profiles.
    After importing, configure JIT password migration (see scripts/README.md).

.PARAMETER ConfigFile
    Path to the configuration file relative to the console project directory.
    Default: appsettings.export-import.json

.PARAMETER VerboseLogging
    Enable verbose (Debug-level) logging in the console application.

.PARAMETER SkipAzurite
    Skip the Azurite port check. Use when pointing to a real Azure Storage account.

.EXAMPLE
    .\Start-LocalImport.ps1

.EXAMPLE
    .\Start-LocalImport.ps1 -ConfigFile "appsettings.export-import.json" -VerboseLogging
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigFile = "appsettings.export-import.json",

    [Parameter(Mandatory = $false)]
    [switch]$VerboseLogging,

    [Parameter(Mandatory = $false)]
    [switch]$SkipAzurite
)

$ErrorActionPreference = "Stop"

# Shared helpers
. (Join-Path $PSScriptRoot "_Common.ps1")

$rootDir       = Split-Path -Parent $PSScriptRoot
$consoleAppDir = Join-Path $rootDir "src\B2CMigrationKit.Console"
$configPath    = Join-Path $consoleAppDir $ConfigFile

# ─── Header ─────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  B2C Migration Kit - Import (Simple Mode)" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# Validate config file
if (-not (Test-Path $configPath)) {
    Write-Err "Configuration file not found: $configPath"
    Write-Info "Copy appsettings.export-import.example.json → $ConfigFile and fill in your credentials."
    exit 1
}
Write-Success "✓ Configuration: $ConfigFile"

# Detect storage mode
$storage   = Get-StorageMode -ConfigPath $configPath
$skipCheck = ($SkipAzurite -or -not $storage.NeedsAzurite)

# Verify Azurite is running (VS Code extension)
Confirm-AzuriteRunning -SkipAzurite $skipCheck

# ─── Run ─────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Info "Starting import: reading blobs → creating users in External ID..."
Write-Host ""

$exitCode = Invoke-ConsoleApp `
    -AppDir         $consoleAppDir `
    -Operation      "import" `
    -ConfigFile     $ConfigFile `
    -VerboseLogging $VerboseLogging.IsPresent

Write-Host ""
if ($exitCode -eq 0) {
    Write-Success "═══════════════════════════════════════════════════════"
    Write-Success "  Import completed! Users created in External ID."
    Write-Success ""
    Write-Success "  Users have RequiresMigration=true — configure JIT"
    Write-Success "  for seamless password migration on first login."
    Write-Success ""
    Write-Success "  Next step — set up JIT password migration:"
    Write-Success "    .\New-LocalJitRsaKeyPair.ps1"
    Write-Success "    .\Configure-ExternalIdJit.ps1 ..."
    Write-Success "═══════════════════════════════════════════════════════"
} else {
    Write-Err "═══════════════════════════════════════════════════════"
    Write-Err "  Import failed (exit code $exitCode)"
    Write-Err "═══════════════════════════════════════════════════════"
}
Write-Host ""
exit $exitCode
