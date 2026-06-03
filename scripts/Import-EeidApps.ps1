# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
<#
.SYNOPSIS
    Imports B2C app registrations into External ID and transforms API connectors
    into onTokenIssuanceStart Custom Authentication Extensions (CAE).

.DESCRIPTION
    Reads the JSON file produced by Export-B2CApps.ps1 and:

    1. Re-creates each migratable app registration in the External ID tenant
       (framework apps like b2c-extensions-app are skipped).
    2. For every B2C API connector that was attached to a user flow, creates:
       a) An app registration for the CAE (with
          CustomAuthenticationExtension.Receive.Payload permission)
       b) An onTokenIssuanceStartCustomExtension pointing to the same target URL
       c) Optionally creates an event listener linking the CAE to migrated apps

    Important: B2C API connectors authenticate via Basic Auth / client
    certificate / API key, while External ID CAEs use Azure AD token
    authentication. After running this script you must update your API
    endpoints to validate Azure AD bearer tokens instead of the legacy
    auth mechanism. The script outputs the resourceId (audience) each API
    must accept.

.PARAMETER TargetTenantId
    The External ID tenant ID where resources will be created.

.PARAMETER InputFile
    Path to the export JSON produced by Export-B2CApps.ps1.
    Default: app-migration-export.json

.PARAMETER SkipApps
    Skip app registration migration (only process API connectors → CAE).

.PARAMETER SkipConnectors
    Skip API connector → CAE transformation (only migrate app registrations).

.PARAMETER ConnectorIds
    Optional array of specific API connector IDs to transform. If omitted,
    all connectors found in the export are transformed.

.PARAMETER CaeTargetUrl
    Override the target URL for the CAE endpoint. When provided, the CAE
    will point to this URL instead of the original B2C API connector URL.
    Use this when your CAE endpoint validates Azure AD bearer tokens at a
    different URL than the original B2C API connector (which used Basic
    Auth / API Key).
    Must be an absolute HTTPS URL.
    NOTE: This applies to ALL connectors being migrated in the run. For
    per-connector URLs, run the script once per connector with -ConnectorNames.

.PARAMETER DryRun
    Print what would be created without making any Graph API calls.

.EXAMPLE
    .\Import-EeidApps.ps1 -TargetTenantId "contoso-eeid.onmicrosoft.com" `
        -InputFile "app-migration-export.json"
    Imports all apps and transforms all connectors.

.EXAMPLE
    .\Import-EeidApps.ps1 -TargetTenantId "tenant-id" -SkipApps
    Only transforms API connectors into CAEs (apps already migrated).

.EXAMPLE
    .\Import-EeidApps.ps1 -TargetTenantId "tenant-id" -DryRun
    Preview what would be created without making changes.

.EXAMPLE
    .\Import-EeidApps.ps1 -TargetTenantId "tenant-id" -AppNames "MyApp","AnotherApp"
    Migrate only specific apps by display name (partial match supported).

.EXAMPLE
    .\Import-EeidApps.ps1 -TargetTenantId "tenant-id" -ConnectorNames "LocalDevTest*" -SkipApps
    Migrate only connectors whose name matches the wildcard pattern.

.EXAMPLE
    .\Import-EeidApps.ps1 -TargetTenantId "tenant-id" `
        -ConnectorNames "MyConnector" `
        -CaeTargetUrl "https://myapp.azurewebsites.net/api/CaeTokenIssuance"
    Migrate a connector and point the CAE to a new endpoint URL.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "External ID tenant ID or domain")]
    [string]$TargetTenantId,

    [Parameter(Mandatory = $false)]
    [string]$InputFile = "app-migration-export.json",

    [switch]$SkipApps,
    [switch]$SkipConnectors,

    [Parameter(Mandatory = $false)]
    [string[]]$ConnectorIds,

    [Parameter(Mandatory = $false,
     HelpMessage = "Filter apps by display name. Supports wildcards (e.g. 'MyApp*'). Migrates all if omitted.")]
    [string[]]$AppNames,

    [Parameter(Mandatory = $false,
     HelpMessage = "Filter connectors by display name. Supports wildcards (e.g. 'LocalDev*'). Migrates all if omitted.")]
    [string[]]$ConnectorNames,

    [switch]$DryRun,

    [Parameter(Mandatory = $false,
     HelpMessage = "EEID app IDs to link to CAEs via event listeners. If omitted and apps were migrated, migrated apps are linked automatically.")]
    [string[]]$LinkedAppIds,

    [Parameter(Mandatory = $false,
     HelpMessage = "Claim names that your API returns. Used to populate claimsForTokenConfiguration on the CAE. E.g. 'role','department'")]
    [string[]]$ClaimsForToken,

    [Parameter(Mandatory = $false,
     HelpMessage = "Override the CAE endpoint URL. Use when the CAE endpoint differs from the original B2C API connector URL. Must be HTTPS. Applies to all connectors in this run.")]
    [string]$CaeTargetUrl
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_Common.ps1")

# ─── Well-known permission ID ─────────────────────────────────────────────────
$PERM_CAE_RECEIVE_PAYLOAD = "214e810f-fda8-4fd7-a475-29461495eb00"

# ─── Helper: map B2C signInAudience to EEID-compatible value ──────────────────
function ConvertTo-EeidSignInAudience {
    param([string]$B2CAudience)
    switch ($B2CAudience) {
        'AzureADandPersonalMicrosoftAccount' { return 'AzureADMyOrg' }
        'AzureADMultipleOrgs'                { return 'AzureADMyOrg' }
        default                              { return 'AzureADMyOrg' }
    }
}

# ─── Validate -CaeTargetUrl early ─────────────────────────────────────────────
if ($CaeTargetUrl) {
    try {
        $parsedCaeUrl = [System.Uri]::new($CaeTargetUrl)
        if ($parsedCaeUrl.Scheme -ne 'https') {
            Write-Err "-CaeTargetUrl must use HTTPS. Got: $($parsedCaeUrl.Scheme)"
            exit 1
        }
        if ([string]::IsNullOrEmpty($parsedCaeUrl.Host)) {
            Write-Err "-CaeTargetUrl must have a valid host."
            exit 1
        }
    }
    catch {
        Write-Err "-CaeTargetUrl is not a valid URL: $CaeTargetUrl"
        exit 1
    }
}

# ══════════════════════════════════════════════════════════════════════════════
#  Main
# ══════════════════════════════════════════════════════════════════════════════

Write-SectionHeader "Import B2C Apps → External ID  +  API Connectors → CAE"

if ($DryRun) { Write-Warn "DRY-RUN mode — no changes will be made" }
Write-Info "Target tenant: $TargetTenantId"
Write-Info "Input file:    $InputFile"
Write-Host ""

# ─── 0. Read export file ─────────────────────────────────────────────────────
if (-not (Test-Path $InputFile)) {
    Write-Err "Export file not found: $InputFile"
    Write-Info "Run Export-B2CApps.ps1 first."
    exit 1
}
$export = Get-Content -Path $InputFile -Raw | ConvertFrom-Json

Write-Info "Export date:        $($export.exportDate)"
Write-Info "B2C tenant:         $($export.b2cTenantId)"
Write-Info "Apps in export:     $($export.applications.Count)"
Write-Info "Connectors:         $($export.apiConnectors.Count)"
Write-Info "User flows:         $($export.userFlows.Count)"
Write-Host ""

# Framework app names for filtering
$frameworkNames = @($export.frameworkAppNames)

# ─── 1. Authenticate ─────────────────────────────────────────────────────────
Write-SubHeader "Step 1 · Authenticate to External ID"

$scopes = @(
    "https://graph.microsoft.com/Application.ReadWrite.All"
)
if (-not $SkipConnectors) {
    $scopes += "https://graph.microsoft.com/CustomAuthenticationExtension.ReadWrite.All"
    $scopes += "https://graph.microsoft.com/EventListener.ReadWrite.All"
}

if ($DryRun) {
    Write-Warn "Skipping authentication (dry-run)"
    $headers = @{}
}
else {
    $token = Get-DeviceCodeToken -TenantId $TargetTenantId -TenantLabel "EEID" -Scopes $scopes
    $headers = @{ Authorization = "Bearer $token" }
}

# ──────────────────────────────────────────────────────────────────────────────
#  PART A — App Registration Migration
# ──────────────────────────────────────────────────────────────────────────────

$appIdMap = @{}   # B2C appId → EEID appId (for linking event listeners)

if (-not $SkipApps) {
    Write-SubHeader "Step 2 · Migrate App Registrations"

    $migratable = $export.applications | Where-Object {
        $_.displayName -notin $frameworkNames -and
        $_.displayName -notlike 'b2c-extensions-app*'
    }

    # Filter by -AppNames if provided (wildcards supported)
    if ($AppNames -and $AppNames.Count -gt 0) {
        $migratable = $migratable | Where-Object {
            $name = $_.displayName
            $AppNames | Where-Object { $name -like $_ }
        }
        Write-Info "  Filtering to apps matching: $($AppNames -join ', ')"
    }
    Write-Info "  Migratable apps: $($migratable.Count)"

    foreach ($srcApp in $migratable) {
        Write-Info "  Processing: $($srcApp.displayName)"

        # Check if app already exists in target by displayName
        if (-not $DryRun) {
            $existing = Invoke-Graph -Method GET `
                -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=displayName eq '$($srcApp.displayName -replace "'","''")'" `
                -Headers $headers
            if ($existing.value -and $existing.value.Count -gt 0) {
                Write-Warn "    Already exists → $($existing.value[0].appId)"
                $appIdMap[$srcApp.appId] = $existing.value[0].appId
                continue
            }
        }

        # Build target app body
        $newApp = @{
            displayName     = $srcApp.displayName
            signInAudience  = ConvertTo-EeidSignInAudience $srcApp.signInAudience
        }

        # Redirect URIs
        if ($srcApp.web.redirectUris -and $srcApp.web.redirectUris.Count -gt 0) {
            $newApp.web = @{
                redirectUris          = @($srcApp.web.redirectUris)
                implicitGrantSettings = @{
                    enableAccessTokenIssuance = [bool]($srcApp.web.implicitGrantSettings.enableAccessTokenIssuance)
                    enableIdTokenIssuance     = [bool]($srcApp.web.implicitGrantSettings.enableIdTokenIssuance)
                }
            }
        }
        if ($srcApp.spa.redirectUris -and $srcApp.spa.redirectUris.Count -gt 0) {
            $newApp.spa = @{ redirectUris = @($srcApp.spa.redirectUris) }
        }
        if ($srcApp.publicClient.redirectUris -and $srcApp.publicClient.redirectUris.Count -gt 0) {
            $newApp.publicClient = @{ redirectUris = @($srcApp.publicClient.redirectUris) }
        }

        # Identifier URIs (skip B2C-specific ones that won't resolve)
        if ($srcApp.identifierUris -and $srcApp.identifierUris.Count -gt 0) {
            $filteredUris = @($srcApp.identifierUris | Where-Object { $_ -notlike '*b2clogin.com*' })
            if ($filteredUris.Count -gt 0) {
                $newApp.identifierUris = $filteredUris
            }
        }

        # App roles
        if ($srcApp.appRoles -and $srcApp.appRoles.Count -gt 0) {
            $newApp.appRoles = @($srcApp.appRoles | ForEach-Object {
                @{
                    id                 = $_.id
                    allowedMemberTypes = @($_.allowedMemberTypes)
                    displayName        = $_.displayName
                    description        = $_.description
                    isEnabled          = $_.isEnabled
                    value              = $_.value
                }
            })
        }

        # API scopes
        if ($srcApp.api.oauth2PermissionScopes -and $srcApp.api.oauth2PermissionScopes.Count -gt 0) {
            $newApp.api = @{
                oauth2PermissionScopes = @($srcApp.api.oauth2PermissionScopes | ForEach-Object {
                    @{
                        id                      = $_.id
                        adminConsentDisplayName  = $_.adminConsentDisplayName
                        adminConsentDescription  = $_.adminConsentDescription
                        userConsentDisplayName   = $_.userConsentDisplayName
                        userConsentDescription   = $_.userConsentDescription
                        value                   = $_.value
                        type                    = $_.type
                        isEnabled               = $_.isEnabled
                    }
                })
            }
        }

        if ($DryRun) {
            Write-Success "    [dry-run] Would create: $($srcApp.displayName)"
            Write-Info    "      signInAudience: $($newApp.signInAudience)"
            if ($newApp.web)          { Write-Info "      web redirects:    $($newApp.web.redirectUris -join ', ')" }
            if ($newApp.spa)          { Write-Info "      spa redirects:    $($newApp.spa.redirectUris -join ', ')" }
            if ($newApp.publicClient) { Write-Info "      native redirects: $($newApp.publicClient.redirectUris -join ', ')" }
        }
        else {
            try {
                $created = Invoke-Graph -Method POST `
                    -Uri "https://graph.microsoft.com/v1.0/applications" `
                    -Headers $headers -Body $newApp

                $appIdMap[$srcApp.appId] = $created.appId
                Write-Success "    Created → $($created.appId)"
            }
            catch {
                Write-Err "    FAILED to create $($srcApp.displayName): $_"
            }
        }
    }

    Write-Info "  Apps processed: $($migratable.Count)"
}
else {
    Write-Info "Skipping app registration migration (--SkipApps)"
}

# ──────────────────────────────────────────────────────────────────────────────
#  PART B — API Connector → CAE transformation
# ──────────────────────────────────────────────────────────────────────────────

if (-not $SkipConnectors -and $export.apiConnectors.Count -gt 0) {
    Write-SubHeader "Step 3 · Transform API Connectors → onTokenIssuanceStart CAE"

    # Determine which connectors to process
    $connectorsToProcess = $export.apiConnectors
    if ($ConnectorIds -and $ConnectorIds.Count -gt 0) {
        $connectorsToProcess = $export.apiConnectors | Where-Object { $_.id -in $ConnectorIds }
        Write-Info "  Filtering to $($connectorsToProcess.Count) connectors by ID"
    }
    elseif ($ConnectorNames -and $ConnectorNames.Count -gt 0) {
        $connectorsToProcess = $export.apiConnectors | Where-Object {
            $name = $_.displayName
            $ConnectorNames | Where-Object { $name -like $_ }
        }
        Write-Info "  Filtering to connectors matching: $($ConnectorNames -join ', ')"
    }

    # Build a lookup: connectorId → list of flows where it's used (and at which step)
    $connectorUsage = @{}
    foreach ($flow in $export.userFlows) {
        foreach ($step in @('postFederationSignup', 'postAttributeCollection', 'preSendingClaims')) {
            $connectorId = $flow.$step
            if ($connectorId) {
                if (-not $connectorUsage[$connectorId]) { $connectorUsage[$connectorId] = @() }
                $connectorUsage[$connectorId] += @{ flowId = $flow.flowId; step = $step }
            }
        }
    }

    # Warn if -CaeTargetUrl applies to multiple connectors
    if ($CaeTargetUrl -and @($connectorsToProcess).Count -gt 1) {
        Write-Warn "  ⚠️  -CaeTargetUrl will be applied to ALL $(@($connectorsToProcess).Count) connectors."
        Write-Warn "     For per-connector URLs, run once per connector with -ConnectorNames."
    }

    $caeResults = @()

    foreach ($connector in $connectorsToProcess) {
        # Determine effective target URL for the CAE
        $effectiveTargetUrl = if ($CaeTargetUrl) { $CaeTargetUrl } else { $connector.targetUrl }

        Write-Info ""
        Write-Info "  Connector: $($connector.displayName)"
        Write-Info "  Original URL: $($connector.targetUrl)"
        if ($CaeTargetUrl) {
            Write-Info "  CAE Target URL: $effectiveTargetUrl (overridden via -CaeTargetUrl)"
        }

        $usage = $connectorUsage[$connector.id]
        if ($usage) {
            foreach ($u in $usage) {
                Write-Info "    Used in flow: $($u.flowId) at step: $($u.step)"
            }
        }
        else {
            Write-Warn "    Not attached to any user flow — transforming anyway"
        }

        # ── B1. Create CAE app registration ──────────────────────────────────
        $caeAppName = "CAE - $($connector.displayName)"

        $targetUri = [System.Uri]$effectiveTargetUrl
        $caeResourceId = "api://$($targetUri.Host)/$([guid]::NewGuid())"

        if ($DryRun) {
            Write-Success "    [dry-run] Would create CAE app: $caeAppName"
            Write-Info    "      resourceId: $caeResourceId"
            if ($ClaimsForToken -and $ClaimsForToken.Count -gt 0) {
                Write-Info "      claimsForTokenConfiguration: $($ClaimsForToken -join ', ')"
            }
            if ($LinkedAppIds -and $LinkedAppIds.Count -gt 0) {
                Write-Info "      Would link to $($LinkedAppIds.Count) explicit app(s) via event listener"
            } elseif (-not $SkipApps) {
                Write-Info "      Would link to all migrated apps via event listener"
            } elseif ($AppNames -and $AppNames.Count -gt 0) {
                Write-Info "      Would look up and link app(s): $($AppNames -join ', ') via event listener"
            } else {
                Write-Warn "      No app context — event listener will be skipped (use -LinkedAppIds to specify)"
            }
            $caeResults += @{
                connectorName  = $connector.displayName
                originalUrl    = $connector.targetUrl
                targetUrl      = $effectiveTargetUrl
                caeAppName     = $caeAppName
                resourceId     = $caeResourceId
            }
            continue
        }

        # Check if CAE app already exists
        $existingCae = Invoke-Graph -Method GET `
            -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=displayName eq '$($caeAppName -replace "'","''")'" `
            -Headers $headers

        if ($existingCae.value -and $existingCae.value.Count -gt 0) {
            $caeApp = $existingCae.value[0]
            Write-Warn "    CAE app already exists → $($caeApp.appId)"
            # resourceId must use the actual appId of the CAE app
            $caeResourceId = "api://$($targetUri.Host)/$($caeApp.appId)"
            # Patch identifierUris if they don't match
            if ($caeApp.identifierUris -notcontains $caeResourceId) {
                try {
                    Invoke-Graph -Method PATCH `
                        -Uri "https://graph.microsoft.com/v1.0/applications/$($caeApp.id)" `
                        -Headers $headers -Body @{ identifierUris = @($caeResourceId) } | Out-Null
                    Write-Info "    identifierUri updated to use actual appId"
                    # Poll until Graph propagates the identifierUri change (up to 30s)
                    $deadline = (Get-Date).AddSeconds(30)
                    do {
                        Start-Sleep -Seconds 3
                        $refreshed = Invoke-Graph -Method GET `
                            -Uri "https://graph.microsoft.com/v1.0/applications/$($caeApp.id)?`$select=identifierUris" `
                            -Headers $headers
                    } until ($refreshed.identifierUris -contains $caeResourceId -or (Get-Date) -ge $deadline)
                    if ($refreshed.identifierUris -notcontains $caeResourceId) {
                        Write-Warn "    identifierUri may not have propagated yet — proceeding anyway"
                    }
                } catch {
                    Write-Warn "    Could not update identifierUri: $($_.Exception.Message)"
                }
            }
        }
        else {
            $caeAppBody = @{
                displayName            = $caeAppName
                signInAudience         = "AzureADMyOrg"
                requiredResourceAccess = @(
                    @{
                        resourceAppId  = $GRAPH_APP_ID
                        resourceAccess = @(
                            @{
                                id   = $PERM_CAE_RECEIVE_PAYLOAD
                                type = "Role"
                            }
                        )
                    }
                )
            }

            try {
                $caeApp = Invoke-Graph -Method POST `
                    -Uri "https://graph.microsoft.com/v1.0/applications" `
                    -Headers $headers -Body $caeAppBody
                Write-Success "    CAE app created → $($caeApp.appId)"
            }
            catch {
                Write-Err "    FAILED to create CAE app: $_"
                continue
            }

            # resourceId must use the actual appId returned by Graph
            $caeResourceId = "api://$($targetUri.Host)/$($caeApp.appId)"

            # Patch identifierUris now that we have the real appId
            Start-Sleep -Seconds 2
            try {
                Invoke-Graph -Method PATCH `
                    -Uri "https://graph.microsoft.com/v1.0/applications/$($caeApp.id)" `
                    -Headers $headers -Body @{ identifierUris = @($caeResourceId) } | Out-Null
                Write-Info "    identifierUri set to api://$($targetUri.Host)/$($caeApp.appId)"
                # Poll until Graph propagates the identifierUri change (up to 30s)
                $deadline = (Get-Date).AddSeconds(30)
                do {
                    Start-Sleep -Seconds 3
                    $refreshed = Invoke-Graph -Method GET `
                        -Uri "https://graph.microsoft.com/v1.0/applications/$($caeApp.id)?`$select=identifierUris" `
                        -Headers $headers
                } until ($refreshed.identifierUris -contains $caeResourceId -or (Get-Date) -ge $deadline)
                if ($refreshed.identifierUris -notcontains $caeResourceId) {
                    Write-Warn "    identifierUri may not have propagated yet — proceeding anyway"
                }
            } catch {
                Write-Warn "    Could not set identifierUri: $($_.Exception.Message)"
            }

            # Create service principal for admin consent
            try {
                Invoke-Graph -Method POST `
                    -Uri "https://graph.microsoft.com/v1.0/servicePrincipals" `
                    -Headers $headers -Body @{ appId = $caeApp.appId } | Out-Null
            }
            catch {
                Write-Warn "    SP creation may have failed (might already exist)"
            }
        }

        # ── B2. Create onTokenIssuanceStartCustomExtension ───────────────────
        $caeName = "Token Enrichment - $($connector.displayName)"

        # Check if CAE already exists
        $existingCaes = Invoke-Graph -Method GET `
            -Uri "https://graph.microsoft.com/beta/identity/customAuthenticationExtensions" `
            -Headers $headers
        $matchingCae = $existingCaes.value | Where-Object { $_.displayName -eq $caeName }

        if ($matchingCae) {
            Write-Warn "    CAE '$caeName' already exists → $($matchingCae.id)"
            $caeId = $matchingCae.id
            $patchBody = @{}
            if ($ClaimsForToken -and $ClaimsForToken.Count -gt 0) {
                $patchBody.claimsForTokenConfiguration = @($ClaimsForToken | ForEach-Object { @{ claimIdInApiResponse = $_ } })
            }
            if ($CaeTargetUrl) {
                $patchBody.endpointConfiguration = @{
                    "@odata.type" = "#microsoft.graph.httpRequestEndpoint"
                    targetUrl     = $effectiveTargetUrl
                }
                $patchBody.authenticationConfiguration = @{
                    "@odata.type" = "#microsoft.graph.azureAdTokenAuthentication"
                    resourceId    = $caeResourceId
                }
            }
            if ($patchBody.Count -gt 0) {
                try {
                    Invoke-Graph -Method PATCH `
                        -Uri "https://graph.microsoft.com/beta/identity/customAuthenticationExtensions/$caeId" `
                        -Headers $headers `
                        -Body $patchBody
                    if ($CaeTargetUrl) { Write-Success "    CAE endpoint updated to: $effectiveTargetUrl" }
                    if ($patchBody.claimsForTokenConfiguration) { Write-Success "    claimsForTokenConfiguration updated" }
                }
                catch {
                    Write-Warn "    Could not update CAE: $($_.Exception.Message)"
                }
            }
        }
        else {
            $caeBody = @{
                "@odata.type"             = "#microsoft.graph.onTokenIssuanceStartCustomExtension"
                displayName               = $caeName
                description               = "Migrated from B2C API connector: $($connector.displayName). Update this API to accept Azure AD bearer tokens with audience: $caeResourceId"
                endpointConfiguration     = @{
                    "@odata.type" = "#microsoft.graph.httpRequestEndpoint"
                    targetUrl     = $effectiveTargetUrl
                }
                authenticationConfiguration = @{
                    "@odata.type" = "#microsoft.graph.azureAdTokenAuthentication"
                    resourceId    = $caeResourceId
                }
                clientConfiguration       = @{
                    timeoutInMilliseconds = 2000
                    maximumRetries        = 1
                }
            }
            if ($ClaimsForToken -and $ClaimsForToken.Count -gt 0) {
                $caeBody.claimsForTokenConfiguration = @($ClaimsForToken | ForEach-Object { @{ claimIdInApiResponse = $_ } })
            }

            try {
                $caeResult = Invoke-Graph -Method POST `
                    -Uri "https://graph.microsoft.com/beta/identity/customAuthenticationExtensions" `
                    -Headers $headers -Body $caeBody
                $caeId = $caeResult.id
                Write-Success "    CAE created → $caeId"
            }
            catch {
                Write-Err "    FAILED to create CAE: $_"
                $caeId = $null
            }
        }

        # ── B3. Create event listener ─────────────────────────────────────────
        $listenerId = $null
        $listenerAppIds = @()
        if ($LinkedAppIds -and $LinkedAppIds.Count -gt 0) {
            # Explicit override — use exactly what the caller specified
            $listenerAppIds = $LinkedAppIds
        } elseif (-not $SkipApps -and $appIdMap.Count -gt 0) {
            # Apps were migrated in this run — link only those apps
            $listenerAppIds = @($appIdMap.Values)
        } elseif ($SkipApps -and $AppNames -and $AppNames.Count -gt 0) {
            # -SkipApps with -AppNames: look up the named apps in EEID by display name
            Write-Info "    Looking up migrated app(s) in EEID by name..."
            $listenerAppIds = @()
            foreach ($namePattern in $AppNames) {
                try {
                    $found = Invoke-Graph -Method GET `
                        -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=displayName eq '$($namePattern -replace "'","''")'&`$select=appId,displayName" `
                        -Headers $headers
                    if ($found.value -and $found.value.Count -gt 0) {
                        $listenerAppIds += $found.value[0].appId
                        Write-Info "    Found: $($found.value[0].displayName) → $($found.value[0].appId)"
                    } else {
                        Write-Warn "    App '$namePattern' not found in EEID — skipping"
                    }
                } catch {
                    Write-Warn "    Could not look up '$namePattern': $($_.Exception.Message)"
                }
            }
        } else {
            # No app context — cannot safely determine which apps to link
            Write-Warn "    Cannot determine which EEID app(s) to link the event listener to."
            Write-Warn "    Re-run with -LinkedAppIds '<eeid-appId>' to specify the target app(s)."
            Write-Warn "    Skipping event listener creation."
        }

        if ($listenerAppIds.Count -gt 0 -and $caeId) {
            Write-Info "    Creating event listener linking $($listenerAppIds.Count) app(s) → CAE..."

            try {
                $existingListeners = Invoke-Graph -Method GET `
                    -Uri "https://graph.microsoft.com/v1.0/identity/authenticationEventListeners" `
                    -Headers $headers
                $matchingListener = $existingListeners.value | Where-Object {
                    $_.handler.customExtension.id -eq $caeId
                }
            }
            catch { $matchingListener = $null }

            if ($matchingListener) {
                Write-Warn "    Event listener already exists → $($matchingListener.id)"
                $listenerId = $matchingListener.id
            } else {
                $listenerBody = @{
                    "@odata.type" = "#microsoft.graph.onTokenIssuanceStartListener"
                    conditions    = @{
                        applications = @{
                            includeApplications = @($listenerAppIds | ForEach-Object { @{ appId = $_ } })
                        }
                    }
                    handler = @{
                        "@odata.type"   = "#microsoft.graph.onTokenIssuanceStartCustomExtensionHandler"
                        customExtension = @{ id = $caeId }
                    }
                }

                try {
                    $listenerResult = Invoke-Graph -Method POST `
                        -Uri "https://graph.microsoft.com/v1.0/identity/authenticationEventListeners" `
                        -Headers $headers -Body $listenerBody
                    $listenerId = $listenerResult.id
                    Write-Success "    Event listener created → $listenerId"
                }
                catch {
                    Write-Warn "    Event listener creation failed (may need admin consent first): $($_.Exception.Message)"
                }
            }
        }

        $caeResults += @{
            connectorName  = $connector.displayName
            connectorId    = $connector.id
            originalUrl    = $connector.targetUrl
            targetUrl      = $effectiveTargetUrl
            caeAppId       = $caeApp.appId
            caeAppName     = $caeAppName
            resourceId     = $caeResourceId
            caeId          = $caeId
            listenerId     = $listenerId
        }
    }

    # ─── Summary ─────────────────────────────────────────────────────────────
    Write-SubHeader "Step 4 · Migration Summary"

    if ($caeResults.Count -gt 0) {
        Write-SectionHeader "CAE Migration Results" -Color Green

        foreach ($r in $caeResults) {
            Write-Host "  ┌─ Connector: $($r.connectorName)" -ForegroundColor Cyan
            if ($r.originalUrl -ne $r.targetUrl) {
                Write-Host "  │  Original URL: $($r.originalUrl)" -ForegroundColor DarkGray
                Write-Host "  │  CAE URL:      $($r.targetUrl)" -ForegroundColor White
            } else {
                Write-Host "  │  Target URL:  $($r.targetUrl)" -ForegroundColor Gray
            }
            Write-Host "  │  CAE App:     $($r.caeAppName)" -ForegroundColor Gray
            Write-Host "  │  Resource ID: $($r.resourceId)" -ForegroundColor Yellow
            if ($r.caeId) {
                Write-Host "  │  CAE ID:      $($r.caeId)" -ForegroundColor Gray
            }
            if ($r.listenerId) {
                Write-Host "  │  Listener ID: $($r.listenerId)" -ForegroundColor Gray
            }
            Write-Host "  └──────────────────────────────────────────" -ForegroundColor DarkGray
            Write-Host ""
        }

        Write-SectionHeader "Required: Update Your API Endpoints" -Color Yellow
        Write-Host ""
        Write-Warn "B2C API connectors use Basic Auth / API Key / Client Certificate."
        Write-Warn "External ID CAEs use Azure AD bearer token authentication."
        Write-Host ""
        Write-Info "For each API endpoint, you must:"
        Write-Info "  1. Add Azure AD bearer token validation"
        Write-Info "  2. Accept the audience (resourceId) shown above"
        Write-Info "  3. Return claims in the onTokenIssuanceStartCustomExtension response format:"
        Write-Host ""
        Write-Host '  {' -ForegroundColor Gray
        Write-Host '    "data": {' -ForegroundColor Gray
        Write-Host '      "@odata.type": "microsoft.graph.onTokenIssuanceStartResponseData",' -ForegroundColor Gray
        Write-Host '      "actions": [{' -ForegroundColor Gray
        Write-Host '        "@odata.type": "microsoft.graph.tokenIssuanceStart.provideClaimsForToken",' -ForegroundColor Gray
        Write-Host '        "claims": {' -ForegroundColor Gray
        Write-Host '          "claimName1": "claimValue1",' -ForegroundColor Gray
        Write-Host '          "claimName2": ["value1", "value2"]' -ForegroundColor Gray
        Write-Host '        }' -ForegroundColor Gray
        Write-Host '      }]' -ForegroundColor Gray
        Write-Host '    }' -ForegroundColor Gray
        Write-Host '  }' -ForegroundColor Gray
        Write-Host ""
        Write-Info "See: https://learn.microsoft.com/entra/identity-platform/custom-extension-tokenissuancestart-configuration"
        Write-Host ""

        Write-SectionHeader "Next Steps" -Color Cyan
        Write-Info "1. Grant admin consent for CAE apps in the Azure Portal:"
        Write-Info "   → App registrations → <CAE app> → API permissions → Grant admin consent"
        Write-Host ""
        if (-not $ClaimsForToken -or $ClaimsForToken.Count -eq 0) {
            Write-Info "2. (Optional) If your API returns custom claims, declare them so External ID"
            Write-Info "   includes them in tokens. Re-run with: -ClaimsForToken 'claim1','claim2'"
            Write-Info "   Skip this if your API does not return custom claims."
        } else {
            Write-Success "2. claimsForTokenConfiguration configured: $($ClaimsForToken -join ', ')"
        }
        Write-Host ""
        $linkedResults = @($caeResults | Where-Object { $_.listenerId })
        $skippedResults = @($caeResults | Where-Object { -not $_.listenerId })
        if ($linkedResults.Count -gt 0) {
            Write-Success "3. Event listeners created: $($linkedResults.Count) CAE(s) linked to app(s)"
        }
        if ($skippedResults.Count -gt 0) {
            Write-Warn "3. Event listener not created for $($skippedResults.Count) CAE(s)."
            Write-Info "   Re-run with -AppNames or -LinkedAppIds to specify the EEID app to link."
        }
        Write-Host ""
    }
}
elseif (-not $SkipConnectors) {
    Write-Info "No API connectors found in export — skipping CAE transformation"
}
else {
    Write-Info "Skipping connector transformation (--SkipConnectors)"
}

# ─── Final report ─────────────────────────────────────────────────────────────
Write-SectionHeader "Import Complete" -Color Green

if (-not $SkipApps) {
    Write-Success "App registrations migrated: $($appIdMap.Count)"
}
if (-not $SkipConnectors -and $caeResults) {
    Write-Success "API connectors → CAE:      $($caeResults.Count)"
}
Write-Host ""
