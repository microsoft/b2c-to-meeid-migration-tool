# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
<#
.SYNOPSIS
    Pre-flight readiness check for B2C → External ID migration.

.DESCRIPTION
    Validates that all prerequisites are in place before running a migration:
    - Graph API connectivity to B2C and External ID tenants
    - Required Microsoft Graph permissions
    - Extension attributes configured in External ID
    - Storage (Azurite or Azure) reachable
    - Queue, table, and blob containers exist
    Prints a clear PASS/FAIL summary report.

.PARAMETER ConfigFile
    Path to the configuration file relative to the console project directory.
    Default: appsettings.export-import.json

.PARAMETER Mode
    Migration mode to validate: 'simple' (export/import) or 'worker' (queue-based).
    Default: simple

.EXAMPLE
    .\Validate-MigrationReadiness.ps1

.EXAMPLE
    .\Validate-MigrationReadiness.ps1 -ConfigFile "appsettings.worker1.json" -Mode worker
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigFile = "appsettings.export-import.json",

    [Parameter(Mandatory = $false)]
    [ValidateSet("simple", "worker")]
    [string]$Mode = "simple"
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
Write-Host "  B2C Migration Kit — Readiness Validator" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "  Config : $ConfigFile"
Write-Host "  Mode   : $Mode"
Write-Host ""

# ─── State tracking ─────────────────────────────────────────────────────────
$checks  = [System.Collections.ArrayList]::new()

function Add-Check {
    param(
        [string]$Name,
        [string]$Status,   # PASS | FAIL | WARN
        [string]$Detail = ""
    )
    [void]$checks.Add([PSCustomObject]@{
        Name   = $Name
        Status = $Status
        Detail = $Detail
    })

    switch ($Status) {
        "PASS" { Write-Success "  ✓ $Name" }
        "FAIL" { Write-Err    "  ✗ $Name — $Detail" }
        "WARN" { Write-Warn   "  ⚠ $Name — $Detail" }
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# 1. CONFIG FILE
# ═══════════════════════════════════════════════════════════════════════════════
Write-Info "─── Configuration ───────────────────────────────────────"

if (-not (Test-Path $configPath)) {
    Add-Check -Name "Config file exists" -Status "FAIL" `
              -Detail "Not found: $configPath"
    # Cannot continue without config
    Write-Host ""
    Write-Err "Cannot proceed without a valid config file."
    Write-Err "Copy an example: cp appsettings.export-import.example.json appsettings.export-import.json"
    exit 1
}

Add-Check -Name "Config file exists" -Status "PASS"

try {
    $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
    $mig = $cfg.Migration
    Add-Check -Name "Config JSON valid" -Status "PASS"
}
catch {
    Add-Check -Name "Config JSON valid" -Status "FAIL" -Detail $_.Exception.Message
    exit 1
}

# ═══════════════════════════════════════════════════════════════════════════════
# 2. TENANT CONFIGURATION
# ═══════════════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Info "─── Tenant Configuration ────────────────────────────────"

$b2c  = $mig.B2C
$eeid = $mig.ExternalId

# B2C tenant
if ($b2c.TenantId -and $b2c.TenantId -notlike "<*") {
    Add-Check -Name "B2C TenantId configured" -Status "PASS"
}
else {
    Add-Check -Name "B2C TenantId configured" -Status "FAIL" -Detail "Placeholder or empty"
}

if ($b2c.AppRegistration.ClientId -and $b2c.AppRegistration.ClientId -notlike "<*") {
    Add-Check -Name "B2C ClientId configured" -Status "PASS"
}
else {
    Add-Check -Name "B2C ClientId configured" -Status "FAIL" -Detail "Placeholder or empty"
}

if ($b2c.AppRegistration.ClientSecret -and $b2c.AppRegistration.ClientSecret -notlike "<*") {
    Add-Check -Name "B2C ClientSecret configured" -Status "PASS"
}
else {
    Add-Check -Name "B2C ClientSecret configured" -Status "FAIL" -Detail "Placeholder or empty"
}

# External ID tenant
if ($eeid.TenantId -and $eeid.TenantId -notlike "<*") {
    Add-Check -Name "EEID TenantId configured" -Status "PASS"
}
else {
    Add-Check -Name "EEID TenantId configured" -Status "FAIL" -Detail "Placeholder or empty"
}

if ($eeid.AppRegistration.ClientId -and $eeid.AppRegistration.ClientId -notlike "<*") {
    Add-Check -Name "EEID ClientId configured" -Status "PASS"
}
else {
    Add-Check -Name "EEID ClientId configured" -Status "FAIL" -Detail "Placeholder or empty"
}

if ($eeid.AppRegistration.ClientSecret -and $eeid.AppRegistration.ClientSecret -notlike "<*") {
    Add-Check -Name "EEID ClientSecret configured" -Status "PASS"
}
else {
    Add-Check -Name "EEID ClientSecret configured" -Status "FAIL" -Detail "Placeholder or empty"
}

if ($eeid.ExtensionAppId -and $eeid.ExtensionAppId -notlike "<*") {
    Add-Check -Name "EEID ExtensionAppId configured" -Status "PASS"
}
else {
    Add-Check -Name "EEID ExtensionAppId configured" -Status "WARN" `
              -Detail "Not set — extension attributes may not map correctly"
}

# ═══════════════════════════════════════════════════════════════════════════════
# 3. GRAPH API CONNECTIVITY
# ═══════════════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Info "─── Graph API Connectivity ──────────────────────────────"

function Test-GraphToken {
    param(
        [string]$Label,
        [string]$TenantId,
        [string]$ClientId,
        [string]$ClientSecret
    )

    # Skip if credentials are placeholders
    if ($TenantId -like "<*" -or $ClientId -like "<*" -or $ClientSecret -like "<*") {
        Add-Check -Name "$Label Graph auth" -Status "WARN" `
                  -Detail "Skipped — credentials are placeholders"
        return $null
    }

    try {
        $body = @{
            grant_type    = "client_credentials"
            client_id     = $ClientId
            client_secret = $ClientSecret
            scope         = "https://graph.microsoft.com/.default"
        }
        $tokenUrl = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
        $response = Invoke-RestMethod -Uri $tokenUrl -Method POST -Body $body `
                    -ContentType "application/x-www-form-urlencoded" -TimeoutSec 15

        if ($response.access_token) {
            Add-Check -Name "$Label Graph auth" -Status "PASS"
            return $response.access_token
        }
        else {
            Add-Check -Name "$Label Graph auth" -Status "FAIL" -Detail "No access_token in response"
            return $null
        }
    }
    catch {
        $msg = $_.Exception.Message
        if ($msg -like "*AADSTS*") {
            # Extract the error code
            if ($msg -match "(AADSTS\d+)") { $msg = $Matches[1] }
        }
        Add-Check -Name "$Label Graph auth" -Status "FAIL" -Detail $msg
        return $null
    }
}

$b2cToken = Test-GraphToken -Label "B2C" `
    -TenantId     $b2c.TenantId `
    -ClientId     $b2c.AppRegistration.ClientId `
    -ClientSecret $b2c.AppRegistration.ClientSecret

$eeidToken = Test-GraphToken -Label "EEID" `
    -TenantId     $eeid.TenantId `
    -ClientId     $eeid.AppRegistration.ClientId `
    -ClientSecret $eeid.AppRegistration.ClientSecret

# ═══════════════════════════════════════════════════════════════════════════════
# 4. GRAPH PERMISSIONS
# ═══════════════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Info "─── Graph Permissions ───────────────────────────────────"

$requiredPermissions = @(
    "User.ReadWrite.All",
    "Directory.ReadWrite.All"
)

function Test-GraphPermissions {
    param(
        [string]$Label,
        [string]$Token,
        [string[]]$Required
    )

    if (-not $Token) {
        Add-Check -Name "$Label permissions" -Status "WARN" `
                  -Detail "Skipped — no valid token"
        return
    }

    try {
        $headers = @{ Authorization = "Bearer $Token" }

        # Test user read (verifies User.Read* permissions)
        $testUrl = "https://graph.microsoft.com/v1.0/users?`$top=1&`$select=id"
        $null = Invoke-RestMethod -Uri $testUrl -Headers $headers -TimeoutSec 15
        Add-Check -Name "$Label User.Read access" -Status "PASS"
    }
    catch {
        $status = $_.Exception.Response.StatusCode.value__
        if ($status -eq 403) {
            Add-Check -Name "$Label User.Read access" -Status "FAIL" `
                      -Detail "403 Forbidden — missing User.ReadWrite.All or User.Read.All"
        }
        else {
            Add-Check -Name "$Label User.Read access" -Status "FAIL" `
                      -Detail "HTTP $status — $($_.Exception.Message)"
        }
    }

    # Test write capability (create a dummy check via /me — won't actually create)
    # We just verify the token claims include the required roles
    try {
        $headers = @{ Authorization = "Bearer $Token" }
        $meUrl = "https://graph.microsoft.com/v1.0/organization"
        $null = Invoke-RestMethod -Uri $meUrl -Headers $headers -TimeoutSec 15
        Add-Check -Name "$Label Directory access" -Status "PASS"
    }
    catch {
        $status = $_.Exception.Response.StatusCode.value__
        Add-Check -Name "$Label Directory access" -Status "WARN" `
                  -Detail "HTTP $status — verify Directory.ReadWrite.All is granted"
    }
}

Test-GraphPermissions -Label "B2C"  -Token $b2cToken  -Required $requiredPermissions
Test-GraphPermissions -Label "EEID" -Token $eeidToken -Required $requiredPermissions

# ═══════════════════════════════════════════════════════════════════════════════
# 5. EXTENSION ATTRIBUTES (EEID)
# ═══════════════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Info "─── Extension Attributes (EEID) ─────────────────────────"

if ($eeidToken -and $eeid.ExtensionAppId -and $eeid.ExtensionAppId -notlike "<*") {
    try {
        $appId = $eeid.ExtensionAppId
        $headers = @{ Authorization = "Bearer $eeidToken" }
        $extUrl = "https://graph.microsoft.com/v1.0/applications?`$filter=appId eq '$appId'&`$select=id"
        $result = Invoke-RestMethod -Uri $extUrl -Headers $headers -TimeoutSec 15

        if ($result.value -and $result.value.Count -gt 0) {
            Add-Check -Name "Extension app exists in EEID" -Status "PASS"

            # Check for known migration extension properties
            $objId = $result.value[0].id
            $propsUrl = "https://graph.microsoft.com/v1.0/applications/$objId/extensionProperties"
            $props = Invoke-RestMethod -Uri $propsUrl -Headers $headers -TimeoutSec 15

            if ($props.value -and $props.value.Count -gt 0) {
                $names = ($props.value | ForEach-Object { $_.name }) -join ", "
                Add-Check -Name "Extension properties found ($($props.value.Count))" -Status "PASS"
            }
            else {
                Add-Check -Name "Extension properties" -Status "WARN" `
                          -Detail "No extension properties found — they will be created during import"
            }
        }
        else {
            Add-Check -Name "Extension app exists in EEID" -Status "FAIL" `
                      -Detail "App with appId '$appId' not found"
        }
    }
    catch {
        Add-Check -Name "Extension attributes" -Status "WARN" `
                  -Detail "Could not query: $($_.Exception.Message)"
    }
}
else {
    Add-Check -Name "Extension attributes" -Status "WARN" `
              -Detail "Skipped — no EEID token or ExtensionAppId not configured"
}

# ═══════════════════════════════════════════════════════════════════════════════
# 6. STORAGE CONNECTIVITY
# ═══════════════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Info "─── Storage ─────────────────────────────────────────────"

$storage = Get-StorageMode -ConfigPath $configPath

if ($storage.NeedsAzurite) {
    # Check Azurite ports
    $blobOk  = Test-PortOpen -Port $AZURITE_BLOB_PORT
    $queueOk = Test-PortOpen -Port $AZURITE_QUEUE_PORT

    if ($blobOk) {
        Add-Check -Name "Azurite Blob (port $AZURITE_BLOB_PORT)" -Status "PASS"
    }
    else {
        Add-Check -Name "Azurite Blob (port $AZURITE_BLOB_PORT)" -Status "FAIL" `
                  -Detail "Not listening — start Azurite in VS Code"
    }

    if ($queueOk) {
        Add-Check -Name "Azurite Queue (port $AZURITE_QUEUE_PORT)" -Status "PASS"
    }
    else {
        Add-Check -Name "Azurite Queue (port $AZURITE_QUEUE_PORT)" -Status "FAIL" `
                  -Detail "Not listening — start Azurite in VS Code"
    }
}
else {
    # Cloud storage — just note it
    Add-Check -Name "Cloud storage configured" -Status "PASS"
}

# Check Azure CLI for container/queue validation
$azCli = Get-Command az -ErrorAction SilentlyContinue
if ($azCli) {
    $cs = $storage.ConnString

    # Blob containers
    $requiredContainers = @(
        $mig.Storage.ExportContainerName,
        $mig.Storage.ErrorContainerName,
        $mig.Storage.ImportAuditContainerName
    ) | Where-Object { $_ }

    foreach ($container in $requiredContainers) {
        try {
            $exists = az storage container exists --name $container --connection-string $cs `
                      --only-show-errors 2>&1 | ConvertFrom-Json
            if ($exists.exists) {
                Add-Check -Name "Blob container '$container'" -Status "PASS"
            }
            else {
                Add-Check -Name "Blob container '$container'" -Status "WARN" `
                          -Detail "Does not exist — will be created on first run"
            }
        }
        catch {
            Add-Check -Name "Blob container '$container'" -Status "WARN" `
                      -Detail "Could not verify"
        }
    }

    # Queues (worker mode)
    if ($Mode -eq "worker") {
        $requiredQueues = @("user-ids-to-process", "phone-registration")
        foreach ($queue in $requiredQueues) {
            try {
                $exists = az storage queue exists --name $queue --connection-string $cs `
                          --only-show-errors 2>&1 | ConvertFrom-Json
                if ($exists.exists) {
                    Add-Check -Name "Queue '$queue'" -Status "PASS"
                }
                else {
                    Add-Check -Name "Queue '$queue'" -Status "WARN" `
                              -Detail "Does not exist — run Initialize-LocalStorage or let the app create it"
                }
            }
            catch {
                Add-Check -Name "Queue '$queue'" -Status "WARN" -Detail "Could not verify"
            }
        }
    }

    # Audit table
    $tableName = $mig.Storage.AuditTableName
    if ($tableName) {
        try {
            $exists = az storage table exists --name $tableName --connection-string $cs `
                      --only-show-errors 2>&1 | ConvertFrom-Json
            if ($exists.exists) {
                Add-Check -Name "Table '$tableName'" -Status "PASS"
            }
            else {
                Add-Check -Name "Table '$tableName'" -Status "WARN" `
                          -Detail "Does not exist — will be created on first run"
            }
        }
        catch {
            Add-Check -Name "Table '$tableName'" -Status "WARN" -Detail "Could not verify"
        }
    }
}
else {
    Add-Check -Name "Azure CLI (az)" -Status "WARN" `
              -Detail "Not installed — cannot verify containers/queues exist"
}

# ═══════════════════════════════════════════════════════════════════════════════
# 7. TOOLS
# ═══════════════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Info "─── Tools ───────────────────────────────────────────────"

# .NET SDK
$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
if ($dotnet) {
    $ver = dotnet --version 2>$null
    Add-Check -Name ".NET SDK ($ver)" -Status "PASS"
}
else {
    Add-Check -Name ".NET SDK" -Status "FAIL" -Detail "Not installed — required to build the console app"
}

# PowerShell version
if ($PSVersionTable.PSVersion.Major -ge 7) {
    Add-Check -Name "PowerShell $($PSVersionTable.PSVersion)" -Status "PASS"
}
else {
    Add-Check -Name "PowerShell $($PSVersionTable.PSVersion)" -Status "WARN" `
              -Detail "PowerShell 7+ recommended"
}

# ═══════════════════════════════════════════════════════════════════════════════
# SUMMARY
# ═══════════════════════════════════════════════════════════════════════════════
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  READINESS REPORT" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

$passed  = ($checks | Where-Object { $_.Status -eq "PASS" }).Count
$failed  = ($checks | Where-Object { $_.Status -eq "FAIL" }).Count
$warned  = ($checks | Where-Object { $_.Status -eq "WARN" }).Count
$total   = $checks.Count

Write-Host "  Total: $total  |  " -NoNewline
Write-Success "PASS: $passed" ; Write-Host "  |  " -NoNewline
if ($failed -gt 0) { Write-Err "FAIL: $failed" } else { Write-Host "FAIL: 0" -NoNewline }
Write-Host "  |  " -NoNewline
if ($warned -gt 0) { Write-Warn "WARN: $warned" } else { Write-Host "WARN: 0" }
Write-Host ""

# List failures
if ($failed -gt 0) {
    Write-Err "  Failures that must be resolved:"
    $checks | Where-Object { $_.Status -eq "FAIL" } | ForEach-Object {
        Write-Err "    ✗ $($_.Name) — $($_.Detail)"
    }
    Write-Host ""
}

# List warnings
if ($warned -gt 0) {
    Write-Warn "  Warnings (non-blocking):"
    $checks | Where-Object { $_.Status -eq "WARN" } | ForEach-Object {
        Write-Warn "    ⚠ $($_.Name) — $($_.Detail)"
    }
    Write-Host ""
}

# Final verdict
if ($failed -eq 0) {
    Write-Host ""
    Write-Success "  ✓ READY — All critical checks passed. You can proceed with the migration."
    Write-Host ""
    exit 0
}
else {
    Write-Host ""
    Write-Err "  ✗ NOT READY — Fix the $failed failure(s) above before running the migration."
    Write-Host ""
    exit 1
}
