# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
<#
.SYNOPSIS
    Simple Mode — Export phase. Pages all B2C users and writes full profiles
    to Blob Storage as JSON files.

.DESCRIPTION
    This script:
    1. Verifies Azurite is running via the VS Code extension (checks ports 10000/10001)
    2. Pre-creates blob containers
    3. Builds and runs the B2C Migration Kit console with the 'export' operation

    After exporting, run Start-LocalImport.ps1 to create users in External ID.

.PARAMETER ConfigFile
    Path to the configuration file relative to the console project directory.
    Default: appsettings.export-import.json

.PARAMETER VerboseLogging
    Enable verbose (Debug-level) logging in the console application.

.PARAMETER SkipAzurite
    Skip the Azurite port check. Use when pointing to a real Azure Storage account.

.EXAMPLE
    .\Start-LocalExport.ps1

.EXAMPLE
    .\Start-LocalExport.ps1 -ConfigFile "appsettings.export-import.json" -VerboseLogging
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
Write-Host "  B2C Migration Kit - Export (Simple Mode)" -ForegroundColor Cyan
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

# Pre-create storage resources (containers)
if (-not $skipCheck) {
    Initialize-LocalStorage
}

# ─── Run ─────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Info "Starting export: paging B2C users → Blob Storage..."
Write-Host ""

$exitCode = Invoke-ConsoleApp `
    -AppDir         $consoleAppDir `
    -Operation      "export" `
    -ConfigFile     $ConfigFile `
    -VerboseLogging $VerboseLogging.IsPresent

Write-Host ""
if ($exitCode -eq 0) {
    Write-Success "═══════════════════════════════════════════════════════"
    Write-Success "  Export completed! Blobs written to storage."
    Write-Success ""
    Write-Success "  Next step — import users into External ID:"
    Write-Success "    .\Start-LocalImport.ps1"
    Write-Success "═══════════════════════════════════════════════════════"
} else {
    Write-Err "═══════════════════════════════════════════════════════"
    Write-Err "  Export failed (exit code $exitCode)"
    Write-Err "═══════════════════════════════════════════════════════"
}
Write-Host ""
exit $exitCode
