# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
<#
.SYNOPSIS
    Master/Producer phase – fetches all user IDs from B2C and enqueues them
    in batches to an Azure Queue (local Azurite or cloud).

.DESCRIPTION
    This script:
    1. Verifies Azurite is running via the VS Code extension (checks ports 10000/10001)
    2. Pre-creates the storage queue 'user-ids-to-process' and blob containers
    3. Builds and runs the B2C Migration Kit console with the 'harvest' operation

    Azurite must be started manually from VS Code before running this script:
      Ctrl+Shift+P  →  "Azurite: Start Service"

    After harvesting, start one or more worker-migrate instances (each with its own
    App Registration config) to consume the queue in parallel:
      .\Start-LocalWorkerMigrate.ps1 -ConfigFile appsettings.worker1.json
      .\Start-LocalWorkerMigrate.ps1 -ConfigFile appsettings.worker2.json

.PARAMETER ConfigFile
    Path to the configuration file relative to the console project directory.
    Default: appsettings.master.json (dedicated master config with Harvest section)

.PARAMETER VerboseLogging
    Enable verbose (Debug-level) logging in the console application.

.PARAMETER SkipAzurite
    Skip the Azurite port check. Use when pointing to a real Azure Storage account.

.EXAMPLE
    .\Start-LocalHarvest.ps1

.EXAMPLE
    .\Start-LocalHarvest.ps1 -ConfigFile "appsettings.master.json" -VerboseLogging

.EXAMPLE
    .\Start-LocalHarvest.ps1 -SkipAzurite
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigFile = "appsettings.master.json",

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
Write-Host "  B2C Migration Kit - Harvest (Master/Producer phase)" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# Validate config file
if (-not (Test-Path $configPath)) {
    Write-Err "Configuration file not found: $configPath"
    Write-Info "Create it or use -ConfigFile to specify a different path."
    exit 1
}
Write-Success "✓ Configuration: $ConfigFile"

# Detect storage mode
$storage   = Get-StorageMode -ConfigPath $configPath
$skipCheck = ($SkipAzurite -or -not $storage.NeedsAzurite)

# Verify Azurite is running (VS Code extension)
Confirm-AzuriteRunning -SkipAzurite $skipCheck

# Pre-create storage resources (containers + queue)
if (-not $skipCheck) {
    Initialize-LocalStorage
}

# ─── Run ─────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Info "Starting harvest: paging B2C with `$select=id (page size 999) → Azure Queue..."
Write-Info "This is the MASTER phase. Start worker-migrate instances once this completes."
Write-Host ""

$exitCode = Invoke-ConsoleApp `
    -AppDir         $consoleAppDir `
    -Operation      "harvest" `
    -ConfigFile     $ConfigFile `
    -VerboseLogging $VerboseLogging.IsPresent

Write-Host ""
if ($exitCode -eq 0) {
    Write-Success "═══════════════════════════════════════════════════════"
    Write-Success "  Harvest completed! Queue is populated."
    Write-Success ""
    Write-Success "  Next step – start workers (open one terminal per worker):"
    Write-Success "    .\Start-LocalWorkerMigrate.ps1"
    Write-Success "    .\Start-LocalWorkerMigrate.ps1 -ConfigFile appsettings.worker2.json"
    Write-Success "═══════════════════════════════════════════════════════"
} else {
    Write-Err "═══════════════════════════════════════════════════════"
    Write-Err "  Harvest failed (exit code $exitCode)"
    Write-Err "═══════════════════════════════════════════════════════"
}
Write-Host ""
exit $exitCode
