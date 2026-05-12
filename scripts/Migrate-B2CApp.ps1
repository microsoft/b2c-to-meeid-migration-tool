# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
<#
.SYNOPSIS
    End-to-end migration of a single B2C app registration (and its API connectors)
    to Microsoft Entra External ID.

.DESCRIPTION
    Combines Export-B2CApps.ps1 + Import-EeidApps.ps1 into a single per-app
    command. After migration it prints a clear report showing:
      ✅  What was migrated automatically
      ⚠️  What needs manual action
      ❌  What could not be migrated

    B2C Graph API does not expose which user flows belong to which app, so API
    connectors cannot be auto-linked. Use -ConnectorNames to specify which
    connectors belong to the app, or run without it to migrate ALL connectors
    with a confirmation prompt.

.PARAMETER B2CTenantId
    B2C source tenant (ID or domain, e.g. contosob2c.onmicrosoft.com).

.PARAMETER EeidTenantId
    External ID target tenant (ID or domain).

.PARAMETER AppName
    Display name of the app to migrate. Wildcards supported (e.g. "MyApp*").

.PARAMETER ConnectorNames
    Display names of API connectors to migrate with this app.
    Wildcards supported. If omitted, all connectors found in the export are
    migrated and linked to this app.

.PARAMETER ClaimsForToken
    Claim names that your API endpoint returns. Used to populate
    claimsForTokenConfiguration on the CAE so External ID knows which
    custom claims to include in tokens.
    Example: -ClaimsForToken "role","department","subscriptionTier"

.PARAMETER ExportFile
    Path for the intermediate export JSON.
    Default: .\b2c-app-migration-<AppName>-<date>.json

.PARAMETER CaeTargetUrl
    Override the CAE endpoint URL. Use when your CAE endpoint (which
    validates Azure AD bearer tokens) is at a different URL than the
    original B2C API connector (which used Basic Auth / API Key).
    Must be an absolute HTTPS URL.

.PARAMETER SkipExport
    Re-use an existing export file instead of re-running the B2C export.
    Useful when iterating on the import without re-authenticating to B2C.

.PARAMETER DryRun
    Preview what would be created without making any Graph API calls.

.EXAMPLE
    # Minimal — migrates the app and all connectors
    .\Migrate-B2CApp.ps1 `
        -B2CTenantId "contosob2c.onmicrosoft.com" `
        -EeidTenantId "contosoeeid.onmicrosoft.com" `
        -AppName "MyWebApp"

.EXAMPLE
    # Full — specify connectors and declare the claims your API returns
    .\Migrate-B2CApp.ps1 `
        -B2CTenantId "contosob2c.onmicrosoft.com" `
        -EeidTenantId "contosoeeid.onmicrosoft.com" `
        -AppName "MyWebApp" `
        -ConnectorNames "MyWebApp*" `
        -ClaimsForToken "role","department","subscriptionTier"

.EXAMPLE
    # Dry-run first, then for real
    .\Migrate-B2CApp.ps1 -B2CTenantId "..." -EeidTenantId "..." -AppName "MyWebApp" -DryRun
    .\Migrate-B2CApp.ps1 -B2CTenantId "..." -EeidTenantId "..." -AppName "MyWebApp" `
        -SkipExport -ClaimsForToken "role"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$B2CTenantId,

    [Parameter(Mandatory = $true)]
    [string]$EeidTenantId,

    [Parameter(Mandatory = $true,
     HelpMessage = "Display name of the B2C app to migrate. Wildcards supported.")]
    [string]$AppName,

    [Parameter(Mandatory = $false,
     HelpMessage = "API connector display names to migrate. Wildcards supported. Migrates all if omitted.")]
    [string[]]$ConnectorNames,

    [Parameter(Mandatory = $false,
     HelpMessage = "Claims your API endpoint returns (for claimsForTokenConfiguration).")]
    [string[]]$ClaimsForToken,

    [Parameter(Mandatory = $false)]
    [string]$ExportFile,

    [Parameter(Mandatory = $false,
     HelpMessage = "Override the CAE endpoint URL. Use when the CAE endpoint differs from the original B2C API connector URL. Must be HTTPS.")]
    [string]$CaeTargetUrl,

    [switch]$SkipExport,
    [switch]$DryRun
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_Common.ps1")

$ScriptsDir = $PSScriptRoot

if (-not $ExportFile) {
    $safeName = $AppName -replace '[^a-zA-Z0-9_-]', '_'
    $dateStr   = (Get-Date -Format 'yyyyMMdd-HHmm')
    $ExportFile = ".\b2c-app-migration-$safeName-$dateStr.json"
}

# ══════════════════════════════════════════════════════════════════════════════
Write-SectionHeader "B2C → External ID  Per-App Migration"
Write-Host ""
Write-Info "  App:         $AppName"
Write-Info "  B2C tenant:  $B2CTenantId"
Write-Info "  EEID tenant: $EeidTenantId"
if ($ConnectorNames) { Write-Info "  Connectors:  $($ConnectorNames -join ', ')" }
else                 { Write-Info "  Connectors:  (all connectors in export)" }
if ($ClaimsForToken) { Write-Info "  Claims:      $($ClaimsForToken -join ', ')" }
if ($CaeTargetUrl)  { Write-Info "  CAE URL:     $CaeTargetUrl" }
if ($DryRun)         { Write-Warn "  DRY-RUN — no changes will be made" }
Write-Host ""

# ──────────────────────────────────────────────────────────────────────────────
#  Step 1 · Export from B2C
# ──────────────────────────────────────────────────────────────────────────────
if ($SkipExport) {
    if (-not (Test-Path $ExportFile)) {
        Write-Err "-SkipExport specified but file not found: $ExportFile"
        exit 1
    }
    Write-Info "Using existing export: $ExportFile"
}
else {
    Write-SubHeader "Step 1 · Export from B2C"
    & "$ScriptsDir\Export-B2CApps.ps1" `
        -TenantId $B2CTenantId `
        -OutputFile $ExportFile

    if ($LASTEXITCODE -ne 0) {
        Write-Err "Export failed — aborting."
        exit 1
    }
}

# ──────────────────────────────────────────────────────────────────────────────
#  Step 2 · Analyse export for this app
# ──────────────────────────────────────────────────────────────────────────────
Write-SubHeader "Step 2 · Analyse Export"

$export = Get-Content $ExportFile -Raw | ConvertFrom-Json

# Find matching apps
$matchedApps = @($export.applications | Where-Object {
    $_.displayName -notlike 'b2c-extensions-app*' -and
    $_.displayName -notin @($export.frameworkAppNames) -and
    ($_.displayName -like $AppName)
})

if ($matchedApps.Count -eq 0) {
    Write-Err "No app found matching '$AppName' in export."
    Write-Info "Available apps:"
    $export.applications |
        Where-Object { $_.displayName -notin @($export.frameworkAppNames) -and $_.displayName -notlike 'b2c-extensions-app*' } |
        ForEach-Object { Write-Info "  - $($_.displayName)" }
    exit 1
}

Write-Success "  Found $($matchedApps.Count) app(s) matching '$AppName':"
foreach ($a in $matchedApps) {
    $flags = @()
    if ($a.web.redirectUris.Count)          { $flags += "$($a.web.redirectUris.Count) web redirect(s)" }
    if ($a.spa.redirectUris.Count)          { $flags += "$($a.spa.redirectUris.Count) SPA redirect(s)" }
    if ($a.publicClient.redirectUris.Count) { $flags += "$($a.publicClient.redirectUris.Count) native redirect(s)" }
    if ($a.appRoles.Count)                  { $flags += "$($a.appRoles.Count) app role(s)" }
    if ($a.api.oauth2PermissionScopes.Count){ $flags += "$($a.api.oauth2PermissionScopes.Count) scope(s)" }
    $detail = if ($flags) { " — $($flags -join ', ')" } else { "" }
    Write-Host "    • $($a.displayName)  ($($a.appId))$detail" -ForegroundColor White
}

# Find matching connectors
$allConnectors = @($export.apiConnectors)
if ($ConnectorNames -and $ConnectorNames.Count -gt 0) {
    $matchedConnectors = @($allConnectors | Where-Object {
        $name = $_.displayName
        $ConnectorNames | Where-Object { $name -like $_ }
    })
}
else {
    $matchedConnectors = $allConnectors
}

Write-Host ""
if ($matchedConnectors.Count -gt 0) {
    Write-Success "  Connectors to migrate ($($matchedConnectors.Count)):"
    foreach ($c in $matchedConnectors) {
        # Find which user flows use this connector
        $usedIn = @($export.userFlows | Where-Object {
            $_.postFederationSignup    -eq $c.id -or
            $_.postAttributeCollection -eq $c.id -or
            $_.preSendingClaims        -eq $c.id
        })
        $flowList = if ($usedIn.Count -gt 0) {
            " (used in: $($usedIn.flowId -join ', '))"
        } else { " (not attached to any user flow in export)" }
        Write-Host "    • $($c.displayName)  →  $($c.targetUrl)$flowList" -ForegroundColor White
    }
    if (-not $ConnectorNames) {
        Write-Warn ""
        Write-Warn "  NOTE: B2C doesn't expose which user flows belong to which app."
        Write-Warn "  All $($allConnectors.Count) connectors will be migrated. Use -ConnectorNames to filter."
    }
}
else {
    Write-Info "  No connectors found matching filter — only app registration will be migrated."
}

# What cannot be migrated
Write-Host ""
Write-Info "  Items that cannot be auto-migrated:"
$b2cUris = @($matchedApps | ForEach-Object { $_.identifierUris } | Where-Object { $_ -like '*b2clogin.com*' })
if ($b2cUris.Count -gt 0) {
    Write-Warn "    ⚠️  B2C-specific identifier URIs (will be filtered): $($b2cUris -join ', ')"
}
Write-Warn "    ⚠️  Admin consent for CAE app permissions (manual step in Azure Portal)"
Write-Warn "    ⚠️  API endpoint auth: must change from Basic/API Key to Azure AD bearer token"
if (-not $ClaimsForToken) {
    Write-Warn "    ⚠️  claimsForTokenConfiguration: use -ClaimsForToken to declare claims, or set in Portal"
}
$customPolicies = @($export.userFlows | Where-Object { $_.userFlowType -notin @('signUpOrSignIn','signUp','signIn') })
if ($customPolicies.Count -gt 0) {
    Write-Warn "    ❌  Custom policies / non-SUSI flows: not exported (External ID uses different model)"
}

if ($DryRun) {
    Write-Host ""
    Write-Warn "DRY-RUN — showing what import would do:"
}

Write-Host ""

# ──────────────────────────────────────────────────────────────────────────────
#  Step 3 · Import to External ID
# ──────────────────────────────────────────────────────────────────────────────
Write-SubHeader "Step 3 · Import to External ID"

$importArgs = @(
    "-TargetTenantId", $EeidTenantId,
    "-InputFile",      $ExportFile,
    "-AppNames",       $AppName
)

if ($matchedConnectors.Count -gt 0) {
    if ($ConnectorNames -and $ConnectorNames.Count -gt 0) {
        $importArgs += "-ConnectorNames"
        $importArgs += ($ConnectorNames -join ",")   # Import-EeidApps accepts array
    }
    # else: no -ConnectorNames passed = import will use all connectors (same as our intent)
}
else {
    $importArgs += "-SkipConnectors"
}

if ($ClaimsForToken -and $ClaimsForToken.Count -gt 0) {
    $importArgs += "-ClaimsForToken"
    $importArgs += ($ClaimsForToken -join ",")
}

if ($CaeTargetUrl) {
    $importArgs += "-CaeTargetUrl"
    $importArgs += $CaeTargetUrl
}

if ($DryRun) {
    $importArgs += "-DryRun"
}

& "$ScriptsDir\Import-EeidApps.ps1" @importArgs

# ──────────────────────────────────────────────────────────────────────────────
#  Step 4 · Migration Report
# ──────────────────────────────────────────────────────────────────────────────
Write-SectionHeader "Migration Report — $AppName"
Write-Host ""

Write-Host "  AUTOMATED" -ForegroundColor Green
Write-Host "  ─────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Success "  ✅  App registration re-created in External ID"
if ($matchedConnectors.Count -gt 0) {
    Write-Success "  ✅  CAE app registration + onTokenIssuanceStartCustomExtension per connector"
    Write-Success "  ✅  Event listeners created → all EEID apps linked to CAE"
    if ($ClaimsForToken) {
        Write-Success "  ✅  claimsForTokenConfiguration set: $($ClaimsForToken -join ', ')"
    }
}
Write-Host ""

Write-Host "  MANUAL ACTIONS REQUIRED" -ForegroundColor Yellow
Write-Host "  ─────────────────────────────────────────────────────────────" -ForegroundColor DarkGray

if ($matchedConnectors.Count -gt 0) {
    Write-Warn "  ⚠️  Grant admin consent for each CAE app:"
    Write-Warn "      Azure Portal → App registrations → [CAE - <connector>] → API permissions"
    Write-Warn "      → Grant admin consent for <tenant>"
    Write-Host ""
    Write-Warn "  ⚠️  Update your API endpoint(s) to accept Azure AD bearer tokens:"
    if ($CaeTargetUrl) {
        Write-Warn "      CAE endpoint: $CaeTargetUrl"
    } else {
        foreach ($c in $matchedConnectors) {
            Write-Warn "      $($c.targetUrl)"
        }
    }
    Write-Warn "      Audience = resourceId printed above (api://<host>/<guid>)"
    Write-Warn "      Remove: Basic Auth / API Key / Client Certificate validation"
    Write-Host ""
    if (-not $ClaimsForToken) {
        Write-Warn "  ⚠️  Configure which claims your API returns:"
        Write-Warn "      External Identities → Custom auth extensions → [Token Enrichment - <connector>]"
        Write-Warn "      → API claims → Add claim"
        Write-Warn "      Or re-run with: -ClaimsForToken 'claim1','claim2' -SkipExport"
        Write-Host ""
    }
}

Write-Host "  NOT MIGRATED" -ForegroundColor Red
Write-Host "  ─────────────────────────────────────────────────────────────" -ForegroundColor DarkGray
Write-Host "  ❌  User flow connector bindings: B2C user flows have no equivalent in External ID." -ForegroundColor Red
Write-Host "      External ID uses event listeners (created above) instead of user-flow-level bindings." -ForegroundColor DarkGray
if ($b2cUris.Count -gt 0) {
    Write-Host "  ❌  B2C identifier URIs filtered: $($b2cUris -join ', ')" -ForegroundColor Red
}
Write-Host "  ❌  B2C custom policies / IEF flows: must be redesigned as External ID user flows." -ForegroundColor Red
Write-Host "  ❌  Client secrets / certificates: must be re-generated in the new app registration." -ForegroundColor Red
Write-Host ""

if ($DryRun) {
    Write-Warn "This was a DRY-RUN. Re-run without -DryRun to apply changes."
    Write-Host ""
}
