# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
<#
.SYNOPSIS
    Async phone-registration worker – drains the phone-registration queue and
    registers MFA phone numbers in Entra External ID at a throttle-safe rate.

.DESCRIPTION
    This script:
    1. Verifies Azurite is running via the VS Code extension (checks ports 10000/10001)
    2. Builds and runs the B2C Migration Kit console with the 'phone-registration' operation

    Azurite must be started manually from VS Code before running this script:
      Ctrl+Shift+P  →  "Azurite: Start Service"

    Run AFTER (or concurrently with) Start-LocalWorkerMigrate.ps1.
    The worker-migrate step automatically enqueues { B2CUserId, EEIDUpn } messages
    to the 'phone-registration' queue as it creates users in EEID.

    The worker:
      - Dequeues { B2CUserId, EEIDUpn } messages from the 'phone-registration' queue
      - Fetches the MFA phone number from B2C at drain time (GET /authentication/phoneMethods)
      - Calls POST /users/{EEIDUpn}/authentication/phoneMethods in EEID for each user
      - Sleeps ThrottleDelayMs (default 2000 ms = 0.5 RPS) between calls
      - Treats 409 Conflict as success (phone already registered – idempotent)
      - Exits automatically after MaxEmptyPolls consecutive empty queue polls

    Prerequisites:
      - EEID app registration must have UserAuthenticationMethod.ReadWrite.All
        (Application) granted and admin-consented.
      - Import must have run with EnqueuePhoneRegistration: true, or messages
        must already be in the 'phone-registration' queue.

.PARAMETER ConfigFile
    Path to the configuration file relative to the console project directory.
    Default: appsettings.phone-registration.json

.PARAMETER VerboseLogging
    Enable verbose (Debug-level) logging in the console application.

.PARAMETER SkipAzurite
    Skip the Azurite port check. Use when pointing to a real Azure Storage account.

.EXAMPLE
    .\Start-LocalPhoneRegistration.ps1

.EXAMPLE
    .\Start-LocalPhoneRegistration.ps1 -VerboseLogging

.EXAMPLE
    .\Start-LocalPhoneRegistration.ps1 -SkipAzurite
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigFile = "appsettings.phone-registration.json",

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
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  B2C Migration Kit - Phone Registration Worker" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════════" -ForegroundColor Cyan
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
Write-Info "Starting phone registration worker..."
Write-Info "Draining 'phone-registration' queue → POST /authentication/phoneMethods"
Write-Info "Worker will stop automatically when the queue has been empty MaxEmptyPolls times."
Write-Host ""

$exitCode = Invoke-ConsoleApp `
    -AppDir         $consoleAppDir `
    -Operation      "phone-registration" `
    -ConfigFile     $ConfigFile `
    -VerboseLogging $VerboseLogging.IsPresent

Write-Host ""
if ($exitCode -eq 0) {
    Write-Success "═══════════════════════════════════════════════════════════"
    Write-Success "  Phone registration completed successfully!"
    Write-Success "═══════════════════════════════════════════════════════════"
} else {
    Write-Err "═══════════════════════════════════════════════════════════"
    Write-Err "  Phone registration finished with errors (exit code $exitCode)"
    Write-Err "  Some messages may still be in the queue for retry."
    Write-Err "  Re-run this script to process remaining messages."
    Write-Err "═══════════════════════════════════════════════════════════"
}
Write-Host ""
exit $exitCode
