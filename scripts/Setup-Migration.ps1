# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
<#
.SYNOPSIS
    Interactive migration wizard — walks through the entire B2C-to-EEID setup end-to-end.

.DESCRIPTION
    Five-step interactive wizard:
      1. Collect tenant information (B2C + External ID)
      2. Create app registrations & generate worker configs
      3. Choose migration mode (Simple or Advanced)
      4. Choose deployment target (Local or Azure)
      5. Print summary & next-step commands

    Run this FIRST. It generates all configuration files and optionally deploys
    infrastructure so you can start migrating immediately.

.EXAMPLE
    # Fully interactive
    .\Setup-Migration.ps1

.EXAMPLE
    # Pre-fill values, non-interactive
    .\Setup-Migration.ps1 -NonInteractive `
        -B2CTenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -B2CTenantDomain "contosob2c.onmicrosoft.com" `
        -EeidTenantId "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy" `
        -EeidTenantDomain "contosoeeid.onmicrosoft.com" `
        -ExtensionAppId "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz" `
        -WorkerCount 4 -Mode Advanced -Target Local

.EXAMPLE
    # Dry run — see what would happen
    .\Setup-Migration.ps1 -WhatIf
#>

param(
    [switch]$NonInteractive,

    [string]$B2CTenantId,
    [string]$B2CTenantDomain,
    [string]$EeidTenantId,
    [string]$EeidTenantDomain,
    [string]$ExtensionAppId,

    [ValidateRange(1, 16)]
    [int]$WorkerCount = 5,

    [ValidateSet("Simple", "Advanced")]
    [string]$Mode,

    [ValidateSet("Local", "Azure")]
    [string]$Target,

    # Azure-specific (only when Target = Azure)
    [string]$ResourceGroup,
    [string]$Location = "eastus2",

    [ValidateRange(1, 5)]
    [int]$SecretExpiryYears = 2,

    [switch]$WhatIf
)

$ErrorActionPreference = "Stop"

. (Join-Path $PSScriptRoot "_Common.ps1")

$rootDir       = Split-Path -Parent $PSScriptRoot
$consoleAppDir = Join-Path $rootDir "src" "B2CMigrationKit.Console"

# ─── Validation helpers ────────────────────────────────────────────────────────

function Test-IsGuid {
    param([string]$Value)
    return $Value -match '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$'
}

function Test-IsDomain {
    param([string]$Value)
    return $Value -match '\.onmicrosoft\.com$'
}

function Test-IsExtensionAppId {
    param([string]$Value)
    # Extension app IDs are GUIDs without hyphens (32 hex chars)
    return $Value -match '^[0-9a-fA-F]{32}$'
}

# Interactive prompt with validation and default value
function Read-ValidatedInput {
    param(
        [string]$Prompt,
        [string]$Default,
        [string]$ValidationKind,   # guid | domain | extensionAppId | choice | any
        [string[]]$ValidChoices,
        [bool]$Required = $true
    )

    while ($true) {
        $defaultDisplay = if ($Default) { " [$Default]" } else { "" }
        $raw = Read-Host "$Prompt$defaultDisplay"

        if ([string]::IsNullOrWhiteSpace($raw)) {
            if ($Default) { return $Default }
            if (-not $Required) { return "" }
            Write-Warn "  This field is required."
            continue
        }

        $value = $raw.Trim()

        switch ($ValidationKind) {
            "guid" {
                if (Test-IsGuid $value) { return $value }
                Write-Warn "  Invalid GUID format. Expected: xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
            }
            "domain" {
                if (Test-IsDomain $value) { return $value }
                Write-Warn "  Must end with .onmicrosoft.com"
            }
            "extensionAppId" {
                if (Test-IsExtensionAppId $value) { return $value }
                # Also accept GUID with hyphens and strip them
                $stripped = $value -replace '-', ''
                if (Test-IsExtensionAppId $stripped) {
                    Write-Info "  Converted to: $stripped (hyphens removed)"
                    return $stripped
                }
                Write-Warn "  Expected 32 hex characters (GUID without hyphens)"
            }
            "choice" {
                if ($value -in $ValidChoices) { return $value }
                Write-Warn "  Valid choices: $($ValidChoices -join ', ')"
            }
            default {
                return $value
            }
        }
    }
}

# ─── Banner ────────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Magenta
Write-Host "║                                                              ║" -ForegroundColor Magenta
Write-Host "║     B2C → External ID  Migration Setup Wizard                ║" -ForegroundColor Magenta
Write-Host "║                                                              ║" -ForegroundColor Magenta
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Magenta
Write-Host ""

if ($WhatIf) {
    Write-Warn "═══ DRY RUN — no Graph calls, no files written, no infra deployed ═══"
    Write-Host ""
}

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 1: Collect Tenant Information
# ═══════════════════════════════════════════════════════════════════════════════

Write-SectionHeader "Step 1 / 5 — Tenant Information" -Color Cyan

# Detect existing config to pre-fill
$existingConfigs = @()
for ($i = 1; $i -le 16; $i++) {
    $p = Join-Path $consoleAppDir "appsettings.worker$i.json"
    if (Test-Path $p) { $existingConfigs += $p }
}

$prefilledFromConfig = $false
if ($existingConfigs.Count -gt 0 -and -not $B2CTenantId) {
    try {
        $existing = Get-Content $existingConfigs[0] -Raw | ConvertFrom-Json
        if (-not $B2CTenantId)     { $B2CTenantId     = $existing.Migration.B2C.TenantId }
        if (-not $B2CTenantDomain) { $B2CTenantDomain = $existing.Migration.B2C.TenantDomain }
        if (-not $EeidTenantId)    { $EeidTenantId    = $existing.Migration.ExternalId.TenantId }
        if (-not $EeidTenantDomain){ $EeidTenantDomain= $existing.Migration.ExternalId.TenantDomain }
        if (-not $ExtensionAppId)  { $ExtensionAppId  = $existing.Migration.ExternalId.ExtensionAppId }
        $prefilledFromConfig = $true
        Write-Info "Pre-filled tenant info from existing config: $(Split-Path $existingConfigs[0] -Leaf)"
    }
    catch { }
}

if ($NonInteractive) {
    # Validate all required fields are present
    $missing = @()
    if (-not (Test-IsGuid $B2CTenantId))           { $missing += "B2CTenantId" }
    if (-not (Test-IsDomain $B2CTenantDomain))      { $missing += "B2CTenantDomain" }
    if (-not (Test-IsGuid $EeidTenantId))           { $missing += "EeidTenantId" }
    if (-not (Test-IsDomain $EeidTenantDomain))     { $missing += "EeidTenantDomain" }
    if (-not (Test-IsExtensionAppId $ExtensionAppId)) { $missing += "ExtensionAppId" }

    if ($missing.Count -gt 0) {
        Write-Err "Non-interactive mode: missing or invalid parameters: $($missing -join ', ')"
        Write-Err "Provide all required parameters or run without -NonInteractive."
        exit 1
    }
}
else {
    $B2CTenantId     = Read-ValidatedInput -Prompt "B2C Tenant ID"               -Default $B2CTenantId     -ValidationKind "guid"
    $B2CTenantDomain = Read-ValidatedInput -Prompt "B2C Tenant Domain"           -Default $B2CTenantDomain -ValidationKind "domain"
    $EeidTenantId    = Read-ValidatedInput -Prompt "External ID Tenant ID"       -Default $EeidTenantId    -ValidationKind "guid"
    $EeidTenantDomain= Read-ValidatedInput -Prompt "External ID Tenant Domain"   -Default $EeidTenantDomain -ValidationKind "domain"
    $ExtensionAppId  = Read-ValidatedInput -Prompt "Extension App ID (32 hex, no hyphens)" -Default $ExtensionAppId -ValidationKind "extensionAppId"
}

Write-Host ""
Write-Success "✓ B2C         : $B2CTenantDomain ($B2CTenantId)"
Write-Success "✓ External ID : $EeidTenantDomain ($EeidTenantId)"
Write-Success "✓ Extension   : $ExtensionAppId"

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 2: Create App Registrations
# ═══════════════════════════════════════════════════════════════════════════════

Write-SectionHeader "Step 2 / 5 — App Registrations & Worker Configs" -Color Cyan

# Check existing worker configs
$existingWorkers = @()
for ($i = 1; $i -le 16; $i++) {
    if (Test-Path (Join-Path $consoleAppDir "appsettings.worker$i.json")) {
        $existingWorkers += $i
    }
}

$skipAppReg = $false
if ($existingWorkers.Count -gt 0) {
    Write-Info "Found existing worker configs: $($existingWorkers -join ', ')"
    if (-not $NonInteractive) {
        $choice = Read-Host "Skip app registration? Existing configs will be kept [Y/n]"
        if ($choice -in @('', 'y', 'Y', 'yes')) {
            $skipAppReg = $true
            $WorkerCount = $existingWorkers.Count
            Write-Info "Skipping app registration — using $WorkerCount existing worker(s)."
        }
    }
    else {
        $skipAppReg = $true
        $WorkerCount = $existingWorkers.Count
        Write-Info "Non-interactive: reusing $WorkerCount existing worker config(s)."
    }
}

if (-not $skipAppReg) {
    if (-not $NonInteractive) {
        $wcInput = Read-Host "How many workers? [$WorkerCount]"
        if ($wcInput -and $wcInput -match '^\d+$') {
            $WorkerCount = [int]$wcInput
        }
    }

    Write-Info "Will create $WorkerCount worker app registration pair(s)."
    Write-Host ""

    if ($WhatIf) {
        Write-Warn "[WhatIf] Would authenticate to B2C and External ID via device code"
        Write-Warn "[WhatIf] Would create $WorkerCount B2C apps (User.Read.All) + $WorkerCount EEID apps (User.ReadWrite.All)"
        for ($n = 1; $n -le $WorkerCount; $n++) {
            Write-Warn "[WhatIf] Would write appsettings.worker$n.json"
        }
    }
    else {
        # Authenticate
        $adminScopes = @(
            "https://graph.microsoft.com/Application.ReadWrite.All"
            "https://graph.microsoft.com/User.Read"
        )

        $b2cToken  = Get-DeviceCodeToken -TenantId $B2CTenantId  -TenantLabel "B2C ($B2CTenantDomain)"  -Scopes $adminScopes
        $eeidToken = Get-DeviceCodeToken -TenantId $EeidTenantId -TenantLabel "External ID ($EeidTenantDomain)" -Scopes $adminScopes

        $b2cHeaders  = @{ Authorization = "Bearer $b2cToken";  "Content-Type" = "application/json" }
        $eeidHeaders = @{ Authorization = "Bearer $eeidToken"; "Content-Type" = "application/json" }

        Write-Info "Locating Microsoft Graph service principal..."
        $b2cGraphSpId  = Get-GraphSpId -Headers $b2cHeaders  -TenantLabel "B2C"
        $eeidGraphSpId = Get-GraphSpId -Headers $eeidHeaders -TenantLabel "External ID"

        $workerResults = @()
        for ($n = 1; $n -le $WorkerCount; $n++) {
            Write-SubHeader "Worker $n / $WorkerCount"

            $outFile = Join-Path $consoleAppDir "appsettings.worker$n.json"
            if ((Test-Path $outFile)) {
                Write-Warn "appsettings.worker$n.json already exists — overwriting."
            }

            $retry = $true
            while ($retry) {
                try {
                    $b2cApp = New-WorkerApp `
                        -Headers $b2cHeaders `
                        -AppDisplayName "B2C App Registration (Local - Worker $n)" `
                        -PermissionRoleId $PERM_USER_READ_ALL `
                        -GraphSpId $b2cGraphSpId `
                        -TenantLabel "B2C" `
                        -WorkerNumber $n `
                        -SecretExpiryYears $SecretExpiryYears

                    $eeidApp = New-WorkerApp `
                        -Headers $eeidHeaders `
                        -AppDisplayName "External ID App Registration $n (Local)" `
                        -PermissionRoleId $PERM_USER_READWRITE `
                        -GraphSpId $eeidGraphSpId `
                        -TenantLabel "External ID" `
                        -WorkerNumber $n `
                        -SecretExpiryYears $SecretExpiryYears

                    $content = New-WorkerAppSettingsContent `
                        -WorkerN $n `
                        -B2cTenantId $B2CTenantId `
                        -B2cTenantDomain $B2CTenantDomain `
                        -B2cClientId $b2cApp.ClientId `
                        -B2cClientSecret $b2cApp.ClientSecret `
                        -EeidTenantId $EeidTenantId `
                        -EeidTenantDomain $EeidTenantDomain `
                        -ExtAppId $ExtensionAppId `
                        -EeidClientId $eeidApp.ClientId `
                        -EeidClientSecret $eeidApp.ClientSecret

                    Set-Content -Path $outFile -Value $content -Encoding UTF8 -NoNewline
                    Write-Success "✓ Written: appsettings.worker$n.json"

                    $workerResults += [pscustomobject]@{
                        Worker      = $n
                        B2cClientId = $b2cApp.ClientId
                        EeidClientId= $eeidApp.ClientId
                    }
                    $retry = $false
                }
                catch {
                    Write-Err "Failed to provision worker $n`: $_"
                    if ($NonInteractive) {
                        Write-Err "Non-interactive: aborting."
                        exit 1
                    }
                    $retryChoice = Read-Host "Retry this worker? [Y/n]"
                    if ($retryChoice -in @('n', 'N', 'no')) {
                        Write-Warn "Skipping worker $n."
                        $retry = $false
                    }
                }
            }
        }
    }

    Write-Host ""
    Write-Success "✓ App registrations complete ($WorkerCount workers)"
}

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 3: Choose Migration Mode
# ═══════════════════════════════════════════════════════════════════════════════

Write-SectionHeader "Step 3 / 5 — Migration Mode" -Color Cyan

Write-Info "  [1] Simple   — Export all users, then Import. No queues, no MFA phone migration."
Write-Info "  [2] Advanced — Harvest → parallel Workers → Phone Registration. Full pipeline."
Write-Host ""

if (-not $Mode) {
    if ($NonInteractive) {
        $Mode = "Advanced"
        Write-Info "Non-interactive default: Advanced"
    }
    else {
        $modeChoice = Read-ValidatedInput -Prompt "Mode" -Default "2" -ValidationKind "choice" -ValidChoices @("1","2","Simple","Advanced")
        $Mode = if ($modeChoice -in @("1", "Simple")) { "Simple" } else { "Advanced" }
    }
}

Write-Success "✓ Mode: $Mode"
Write-Host ""

# Generate mode-specific config files
if ($Mode -eq "Simple") {
    $exportImportConfig = Join-Path $consoleAppDir "appsettings.export-import.json"
    if ((Test-Path $exportImportConfig) -and -not $WhatIf) {
        Write-Info "appsettings.export-import.json already exists — keeping."
    }
    elseif ($WhatIf) {
        Write-Warn "[WhatIf] Would generate appsettings.export-import.json"
    }
    else {
        # Use worker1 credentials for the export-import config
        $w1Path = Join-Path $consoleAppDir "appsettings.worker1.json"
        if (Test-Path $w1Path) {
            $w1 = Get-Content $w1Path -Raw | ConvertFrom-Json
            $content = New-WorkerAppSettingsContent `
                -WorkerN 0 `
                -B2cTenantId $B2CTenantId `
                -B2cTenantDomain $B2CTenantDomain `
                -B2cClientId $w1.Migration.B2C.AppRegistration.ClientId `
                -B2cClientSecret $w1.Migration.B2C.AppRegistration.ClientSecret `
                -EeidTenantId $EeidTenantId `
                -EeidTenantDomain $EeidTenantDomain `
                -ExtAppId $ExtensionAppId `
                -EeidClientId $w1.Migration.ExternalId.AppRegistration.ClientId `
                -EeidClientSecret $w1.Migration.ExternalId.AppRegistration.ClientSecret
            # Rename worker-specific fields for export-import
            $content = $content -replace '"migration-audit-worker0.jsonl"', '"migration-audit.jsonl"'
            $content = $content -replace '"worker0-telemetry.jsonl"', '"export-import-telemetry.jsonl"'
            $content = $content -replace '"w0_"', '""'
            $content = $content -replace 'Worker 0', 'Export/Import'
            Set-Content -Path $exportImportConfig -Value $content -Encoding UTF8 -NoNewline
            Write-Success "✓ Written: appsettings.export-import.json"
        }
        else {
            Write-Warn "Cannot generate export-import config — worker1 config not found."
        }
    }
}
else {
    # Advanced mode: master + phone-registration configs
    $masterConfig = Join-Path $consoleAppDir "appsettings.master.json"
    $phoneConfig  = Join-Path $consoleAppDir "appsettings.phone-registration.json"

    $w1Path = Join-Path $consoleAppDir "appsettings.worker1.json"
    $w1Exists = Test-Path $w1Path

    # Master config
    if ((Test-Path $masterConfig) -and -not $WhatIf) {
        Write-Info "appsettings.master.json already exists — keeping."
    }
    elseif ($WhatIf) {
        Write-Warn "[WhatIf] Would generate appsettings.master.json"
    }
    elseif ($w1Exists) {
        $w1 = Get-Content $w1Path -Raw | ConvertFrom-Json
        $content = New-WorkerAppSettingsContent `
            -WorkerN 0 `
            -B2cTenantId $B2CTenantId `
            -B2cTenantDomain $B2CTenantDomain `
            -B2cClientId $w1.Migration.B2C.AppRegistration.ClientId `
            -B2cClientSecret $w1.Migration.B2C.AppRegistration.ClientSecret `
            -EeidTenantId $EeidTenantId `
            -EeidTenantDomain $EeidTenantDomain `
            -ExtAppId $ExtensionAppId `
            -EeidClientId $w1.Migration.ExternalId.AppRegistration.ClientId `
            -EeidClientSecret $w1.Migration.ExternalId.AppRegistration.ClientSecret
        $content = $content -replace '"migration-audit-worker0.jsonl"', '"migration-audit-master.jsonl"'
        $content = $content -replace '"worker0-telemetry.jsonl"', '"master-telemetry.jsonl"'
        $content = $content -replace '"w0_"', '""'
        $content = $content -replace 'Worker 0', 'Master/Harvest'
        Set-Content -Path $masterConfig -Value $content -Encoding UTF8 -NoNewline
        Write-Success "✓ Written: appsettings.master.json"
    }
    else {
        Write-Warn "Cannot generate master config — worker1 config not found."
    }

    # Phone registration config
    if ((Test-Path $phoneConfig) -and -not $WhatIf) {
        Write-Info "appsettings.phone-registration.json already exists — keeping."
    }
    elseif ($WhatIf) {
        Write-Warn "[WhatIf] Would generate appsettings.phone-registration.json"
    }
    elseif ($w1Exists) {
        $w1 = Get-Content $w1Path -Raw | ConvertFrom-Json
        $content = New-WorkerAppSettingsContent `
            -WorkerN 0 `
            -B2cTenantId $B2CTenantId `
            -B2cTenantDomain $B2CTenantDomain `
            -B2cClientId $w1.Migration.B2C.AppRegistration.ClientId `
            -B2cClientSecret $w1.Migration.B2C.AppRegistration.ClientSecret `
            -EeidTenantId $EeidTenantId `
            -EeidTenantDomain $EeidTenantDomain `
            -ExtAppId $ExtensionAppId `
            -EeidClientId $w1.Migration.ExternalId.AppRegistration.ClientId `
            -EeidClientSecret $w1.Migration.ExternalId.AppRegistration.ClientSecret
        $content = $content -replace '"migration-audit-worker0.jsonl"', '"migration-audit-phone.jsonl"'
        $content = $content -replace '"worker0-telemetry.jsonl"', '"phone-registration-telemetry.jsonl"'
        $content = $content -replace '"w0_"', '""'
        $content = $content -replace 'Worker 0', 'Phone Registration'
        Set-Content -Path $phoneConfig -Value $content -Encoding UTF8 -NoNewline
        Write-Success "✓ Written: appsettings.phone-registration.json"
    }
    else {
        Write-Warn "Cannot generate phone config — worker1 config not found."
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 4: Choose Deployment Target
# ═══════════════════════════════════════════════════════════════════════════════

Write-SectionHeader "Step 4 / 5 — Deployment Target" -Color Cyan

Write-Info "  [1] Local  — Run locally with Azurite (dev/test)"
Write-Info "  [2] Azure  — Deploy to Azure VMs via Bicep"
Write-Host ""

if (-not $Target) {
    if ($NonInteractive) {
        $Target = "Local"
        Write-Info "Non-interactive default: Local"
    }
    else {
        $targetChoice = Read-ValidatedInput -Prompt "Target" -Default "1" -ValidationKind "choice" -ValidChoices @("1","2","Local","Azure")
        $Target = if ($targetChoice -in @("1", "Local")) { "Local" } else { "Azure" }
    }
}

Write-Success "✓ Target: $Target"

if ($Target -eq "Azure") {
    if (-not $ResourceGroup) {
        if ($NonInteractive) {
            $ResourceGroup = "rg-b2c-migration"
        }
        else {
            $ResourceGroup = Read-ValidatedInput -Prompt "Resource Group name" -Default "rg-b2c-migration" -ValidationKind "any"
        }
    }

    if (-not $NonInteractive) {
        $locInput = Read-Host "Azure Location [$Location]"
        if ($locInput) { $Location = $locInput }
    }

    Write-Info "Resource Group : $ResourceGroup"
    Write-Info "Location       : $Location"
    Write-Info "VM Count       : $WorkerCount"
    Write-Host ""

    if ($WhatIf) {
        Write-Warn "[WhatIf] Would invoke Deploy-All.ps1 -ResourceGroup $ResourceGroup -Location $Location -VmCount $WorkerCount -WhatIf"
    }
    else {
        Write-Info "Invoking Deploy-All.ps1 ..."
        $deployScript = Join-Path $PSScriptRoot "Deploy-All.ps1"
        & $deployScript -ResourceGroup $ResourceGroup -Location $Location -VmCount $WorkerCount
        if ($LASTEXITCODE -ne 0) {
            Write-Err "Deploy-All.ps1 exited with code $LASTEXITCODE."
            if (-not $NonInteractive) {
                $cont = Read-Host "Continue to summary? [Y/n]"
                if ($cont -in @('n', 'N', 'no')) { exit 1 }
            }
        }
    }
}
else {
    Write-Info "Local deployment selected — no infrastructure to provision."
    Write-Info "Make sure Azurite is running (VS Code: Ctrl+Shift+P → 'Azurite: Start Service')"
}

# ═══════════════════════════════════════════════════════════════════════════════
# STEP 5: Summary & Next Steps
# ═══════════════════════════════════════════════════════════════════════════════

Write-Host ""
Write-Host "╔══════════════════════════════════════════════════════════════╗" -ForegroundColor Green
Write-Host "║  Step 5 / 5 — Summary                                       ║" -ForegroundColor Green
Write-Host "╚══════════════════════════════════════════════════════════════╝" -ForegroundColor Green
Write-Host ""

Write-Info "Tenants:"
Write-Info "  B2C          : $B2CTenantDomain ($B2CTenantId)"
Write-Info "  External ID  : $EeidTenantDomain ($EeidTenantId)"
Write-Info "  Extension App: $ExtensionAppId"
Write-Host ""
Write-Info "Configuration:"
Write-Info "  Workers      : $WorkerCount"
Write-Info "  Mode         : $Mode"
Write-Info "  Target       : $Target"
Write-Host ""

# List generated files
Write-Info "Generated config files:"
$allConfigs = @("appsettings.export-import.json", "appsettings.master.json", "appsettings.phone-registration.json")
for ($i = 1; $i -le $WorkerCount; $i++) { $allConfigs += "appsettings.worker$i.json" }
foreach ($f in $allConfigs) {
    $fp = Join-Path $consoleAppDir $f
    if (Test-Path $fp) {
        Write-Success "  ✓ $f"
    }
}

Write-Host ""
Write-SectionHeader "Next Steps — Run the Migration" -Color Green

if ($Target -eq "Local") {
    Write-Info "1. Validate readiness:"
    Write-Host "     .\scripts\Validate-MigrationReadiness.ps1" -ForegroundColor Gray
    Write-Host ""

    if ($Mode -eq "Simple") {
        Write-Info "2. Export users from B2C:"
        Write-Host "     .\scripts\Start-LocalExport.ps1" -ForegroundColor Gray
        Write-Host ""
        Write-Info "3. Import users into External ID:"
        Write-Host "     .\scripts\Start-LocalImport.ps1" -ForegroundColor Gray
    }
    else {
        Write-Info "2. Start the harvest (run once):"
        Write-Host "     .\scripts\Start-LocalHarvest.ps1" -ForegroundColor Gray
        Write-Host ""
        Write-Info "3. Start workers (one terminal per worker):"
        for ($i = 1; $i -le $WorkerCount; $i++) {
            Write-Host "     .\scripts\Start-LocalWorkerMigrate.ps1 -ConfigFile appsettings.worker$i.json" -ForegroundColor Gray
        }
        Write-Host ""
        Write-Info "4. Start phone registration:"
        Write-Host "     .\scripts\Start-LocalPhoneRegistration.ps1" -ForegroundColor Gray
        Write-Host ""
        Write-Info "5. Monitor progress:"
        Write-Host "     .\scripts\Watch-Migration.ps1 -WorkerCount $WorkerCount" -ForegroundColor Gray
    }
}
else {
    Write-Info "1. Connect to a worker VM:"
    Write-Host "     .\scripts\Connect-Worker.ps1 -WorkerIndex 1" -ForegroundColor Gray
    Write-Host "     ssh -p 2201 azureuser@localhost" -ForegroundColor Gray
    Write-Host ""
    Write-Info "2. On the VM, run the migration:"
    Write-Host "     cd /opt/b2c-migration/app" -ForegroundColor Gray
    Write-Host "     ./B2CMigrationKit.Console harvest --config appsettings.json        # ONE worker only" -ForegroundColor Gray
    Write-Host "     ./B2CMigrationKit.Console worker-migrate --config appsettings.json # ALL workers" -ForegroundColor Gray
    Write-Host "     ./B2CMigrationKit.Console phone-registration --config appsettings.json" -ForegroundColor Gray
    Write-Host ""
    Write-Info "3. Monitor from local machine:"
    Write-Host "     .\scripts\Watch-Migration.ps1 -WorkerCount $WorkerCount" -ForegroundColor Gray
}

Write-Host ""
Write-Success "Setup complete! 🚀"
Write-Host ""
