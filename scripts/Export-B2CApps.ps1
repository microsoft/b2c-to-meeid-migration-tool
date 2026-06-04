# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
<#
.SYNOPSIS
    Exports B2C app registrations, API connectors, and user flow bindings to a JSON file.

.DESCRIPTION
    Connects to the B2C tenant via device-code flow, reads all application
    registrations, API connectors, and user flows (including which connectors
    are attached at which steps), and writes the result to a single JSON file.

    This export is the first step of the app-migration pipeline.
    Use Import-EeidApps.ps1 to create the matching resources in the
    External ID tenant.

    System / framework applications (IdentityExperienceFramework,
    ProxyIdentityExperienceFramework, b2c-extensions-app) are tagged but
    still included so the import script can filter them explicitly.

.PARAMETER TenantId
    The B2C tenant ID to export from.

.PARAMETER OutputFile
    Path for the output JSON file.
    Default: app-migration-export.json  (in the current directory)

.EXAMPLE
    .\Export-B2CApps.ps1 -TenantId "contoso.onmicrosoft.com"
    Exports all apps, connectors, and user flows to app-migration-export.json.

.EXAMPLE
    .\Export-B2CApps.ps1 -TenantId "your-tenant-id" -OutputFile ".\exports\b2c-apps.json"
    Exports to a custom path.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "B2C tenant ID or domain")]
    [string]$TenantId,

    [Parameter(Mandatory = $false)]
    [string]$OutputFile = "app-migration-export.json"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_Common.ps1")

# ─── Well-known B2C framework app names (excluded from migration) ─────────────
$FrameworkAppNames = @(
    'IdentityExperienceFramework',
    'ProxyIdentityExperienceFramework'
)

function Test-IsFrameworkApp {
    param([object]$App)
    if ($App.displayName -in $FrameworkAppNames) { return $true }
    if ($App.displayName -like 'b2c-extensions-app*') { return $true }
    return $false
}

# ══════════════════════════════════════════════════════════════════════════════
#  Main
# ══════════════════════════════════════════════════════════════════════════════

Write-SectionHeader "Export B2C Applications & API Connectors"

Write-Info "Tenant:      $TenantId"
Write-Info "Output file: $OutputFile"
Write-Host ""

# ─── 1. Authenticate ──────────────────────────────────────────────────────────
Write-SubHeader "Step 1 · Authenticate to B2C"
$token = Get-DeviceCodeToken -TenantId $TenantId -TenantLabel "B2C" `
    -Scopes @(
        "https://graph.microsoft.com/Application.Read.All",
        "https://graph.microsoft.com/APIConnectors.ReadWrite.All",
        "https://graph.microsoft.com/IdentityUserFlow.Read.All"
    )
$headers = @{ Authorization = "Bearer $token" }

# ─── 2. Export app registrations ──────────────────────────────────────────────
Write-SubHeader "Step 2 · Export App Registrations"

$selectFields = "id,appId,displayName,signInAudience,web,spa,publicClient," +
    "identifierUris,requiredResourceAccess,optionalClaims,api,appRoles,tags"
$appsUri = "https://graph.microsoft.com/v1.0/applications?`$select=$selectFields&`$top=999"
$apps = Invoke-GraphAllPages -Uri $appsUri -Headers $headers

$clientApps = @()
$frameworkApps = @()
foreach ($app in $apps) {
    if (Test-IsFrameworkApp $app) {
        $frameworkApps += $app
        Write-Warn "  [framework] $($app.displayName) — skipped for migration"
    }
    else {
        $clientApps += $app
        Write-Success "  $($app.displayName)  ($($app.appId))"
    }
}
Write-Info "  Total: $($apps.Count)  |  Migratable: $($clientApps.Count)  |  Framework: $($frameworkApps.Count)"

# ─── 3. Export API connectors ─────────────────────────────────────────────────
Write-SubHeader "Step 3 · Export API Connectors"

$connectorsUri = "https://graph.microsoft.com/v1.0/identity/apiConnectors"
$connectors = Invoke-GraphAllPages -Uri $connectorsUri -Headers $headers

foreach ($c in $connectors) {
    Write-Success "  $($c.displayName)  →  $($c.targetUrl)"
}
Write-Info "  Total connectors: $($connectors.Count)"

# ─── 4. Export user flows + connector bindings ────────────────────────────────
Write-SubHeader "Step 4 · Export User Flows & Connector Bindings"

$flowsUri = "https://graph.microsoft.com/beta/identity/b2cUserFlows?`$select=id,userFlowType,userFlowTypeVersion"
$flows = Invoke-GraphAllPages -Uri $flowsUri -Headers $headers

$flowBindings = @()
foreach ($flow in $flows) {
    Write-Info "  Flow: $($flow.id)"

    # Only signUpOrSignIn and signUp flows support API connectors.
    # Profile edit and password reset flows return errors — skip them gracefully.
    $supportedTypes = @('signUpOrSignIn', 'signUp', 'signIn')
    if ($flow.userFlowType -notin $supportedTypes) {
        Write-Info "    (flow type '$($flow.userFlowType)' does not support connectors — skipped)"
        $flowBindings += @{
            flowId              = $flow.id
            userFlowType        = $flow.userFlowType
            postFederationSignup    = $null
            postAttributeCollection = $null
            preSendingClaims        = $null
        }
        continue
    }

    # Expand all three connector steps; fall back without preSendingClaims if tenant doesn't support it
    $config = $null
    $preSendingClaims = $null
    $fullExpandUri = "https://graph.microsoft.com/beta/identity/b2cUserFlows/$($flow.id)" +
        "/apiConnectorConfiguration?`$expand=postFederationSignup,postAttributeCollection,preSendingClaims"
    try {
        $config = Invoke-Graph -Method GET -Uri $fullExpandUri -Headers $headers
        if ($config.preSendingClaims) { $preSendingClaims = $config.preSendingClaims }
    }
    catch {
        # preSendingClaims not supported in this tenant — retry without it
        $partialExpandUri = "https://graph.microsoft.com/beta/identity/b2cUserFlows/$($flow.id)" +
            "/apiConnectorConfiguration?`$expand=postFederationSignup,postAttributeCollection"
        try {
            $config = Invoke-Graph -Method GET -Uri $partialExpandUri -Headers $headers
        }
        catch {
            # Older flow versions (v1/v2) may not expose apiConnectorConfiguration — skip silently
            Write-Info "    (apiConnectorConfiguration not available for this flow version)"
        }
    }

    $binding = @{
        flowId                  = $flow.id
        userFlowType            = $flow.userFlowType
        postFederationSignup    = if ($config.postFederationSignup.id)    { $config.postFederationSignup.id }    else { $null }
        postAttributeCollection = if ($config.postAttributeCollection.id) { $config.postAttributeCollection.id } else { $null }
        preSendingClaims        = if ($preSendingClaims.id)               { $preSendingClaims.id }               else { $null }
    }

    if ($binding.postFederationSignup)    { Write-Success "    postFederationSignup    → connector $($binding.postFederationSignup)" }
    if ($binding.postAttributeCollection) { Write-Success "    postAttributeCollection → connector $($binding.postAttributeCollection)" }
    if ($binding.preSendingClaims)        { Write-Success "    preSendingClaims        → connector $($binding.preSendingClaims)" }
    if (-not $binding.postFederationSignup -and -not $binding.postAttributeCollection -and -not $binding.preSendingClaims) {
        Write-Info "    (no connectors attached)"
    }

    $flowBindings += $binding
}
Write-Info "  Total flows: $($flows.Count)"

# ─── 5. Build export document & write file ────────────────────────────────────
Write-SubHeader "Step 5 · Write Export File"

$export = @{
    exportDate     = (Get-Date -Format "yyyy-MM-ddTHH:mm:ssZ")
    b2cTenantId    = $TenantId
    applications   = $apps                # includes framework apps (tagged)
    frameworkAppNames = $FrameworkAppNames
    apiConnectors  = $connectors
    userFlows      = $flowBindings
}

$export | ConvertTo-Json -Depth 20 | Set-Content -Path $OutputFile -Encoding utf8

Write-SectionHeader "Export Complete" -Color Green
Write-Success "Saved to: $OutputFile"
Write-Host ""
Write-Info "Next step:"
Write-Info "  .\Import-EeidApps.ps1 -TargetTenantId <EEID-tenant> -InputFile `"$OutputFile`""
Write-Host ""
