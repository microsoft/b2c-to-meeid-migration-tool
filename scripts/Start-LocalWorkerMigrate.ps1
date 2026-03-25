# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
<#
.SYNOPSIS
    Worker-migrate phase – dequeues user-ID batches, fetches full profiles from
    B2C via Graph $batch, creates them in Entra External ID, and enqueues phone
    tasks. Combines what used to be separate worker-export + import steps into
    one, with no blob files.

.DESCRIPTION
    This script:
    1. Verifies Azurite is running via the VS Code extension (checks ports 10000/10001)
    2. Builds and runs the B2C Migration Kit console with the 'worker-migrate' operation

    Azurite must be started manually from VS Code before running this script:
      Ctrl+Shift+P  →  "Azurite: Start Service"

    Run this AFTER Start-LocalHarvest.ps1 has populated the queue.
    You can open multiple terminals and run this script simultaneously,
    each pointing to a different App Registration config, to multiply throughput:

      Terminal 1:  .\Start-LocalWorkerMigrate.ps1
      Terminal 2:  .\Start-LocalWorkerMigrate.ps1 -ConfigFile appsettings.worker2.json
      Terminal 3:  .\Start-LocalWorkerMigrate.ps1 -ConfigFile appsettings.worker3.json

    Each worker independently:
      1. Dequeues a message (20 user IDs) from 'user-ids-to-process'
      2. Calls Graph $batch to fetch full profiles from B2C
      3. Transforms (UPN domain rewrite, extension attrs, email identity, random password)
      4. Creates each user in Entra External ID
      5. Writes Created/Duplicate/Failed to the 'migration-audit' Table Storage
      6. Enqueues { B2CUserId, EEIDUpn } to 'phone-registration' queue
      7. Deletes the queue message (ACK)

    If a worker crashes, the message reappears after the visibility timeout (5 min)
    and will be retried by any available worker.

.PARAMETER ConfigFile
    Path to the configuration file relative to the console project directory.
    Default: appsettings.worker1.json
    For multi-worker runs use per-worker configs: appsettings.worker2.json, etc.

.PARAMETER VerboseLogging
    Enable verbose (Debug-level) logging in the console application.

.PARAMETER SkipAzurite
    Skip the Azurite port check. Use when pointing to a real Azure Storage account.

.EXAMPLE
    .\Start-LocalWorkerMigrate.ps1

.EXAMPLE
    .\Start-LocalWorkerMigrate.ps1 -ConfigFile "appsettings.worker2.json" -VerboseLogging

.EXAMPLE
    .\Start-LocalWorkerMigrate.ps1 -SkipAzurite
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigFile = "appsettings.worker1.json",

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
Write-Host "  B2C Migration Kit - Worker Migrate (Consumer phase)" -ForegroundColor Cyan
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

# ─── Run ─────────────────────────────────────────────────────────────────────
Write-Host ""
Write-Info "Starting worker-migrate: dequeue → Graph `$batch (B2C) → POST users (EEID) → phone queue..."
Write-Info "Worker will stop automatically when the queue is empty (MaxEmptyPolls reached)."
Write-Host ""

$exitCode = Invoke-ConsoleApp `
    -AppDir         $consoleAppDir `
    -Operation      "worker-migrate" `
    -ConfigFile     $ConfigFile `
    -VerboseLogging $VerboseLogging.IsPresent

Write-Host ""
if ($exitCode -eq 0) {
    Write-Success "═══════════════════════════════════════════════════════"
    Write-Success "  Worker migrate completed!"
    Write-Success ""
    Write-Success "  Next step – drain the phone-registration queue:"
    Write-Success "    .\Start-LocalPhoneRegistration.ps1"
    Write-Success "═══════════════════════════════════════════════════════"
} else {
    Write-Err "═══════════════════════════════════════════════════════"
    Write-Err "  Worker migrate finished with errors (exit code $exitCode)"
    Write-Err "  Some messages may still be in the queue for retry."
    Write-Err "  Re-run this script to process remaining messages."
    Write-Err "═══════════════════════════════════════════════════════"
}
Write-Host ""
exit $exitCode
