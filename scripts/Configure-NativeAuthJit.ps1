# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
<#
.SYNOPSIS
    Configures Native Authentication for JIT password migration testing.

.DESCRIPTION
    Creates (or reuses) an app registration with native authentication enabled,
    creates a user flow, links the flow to the app, and updates the existing
    onPasswordSubmit event listener to include the new Native Auth app.

    This enables testing JIT password migration via Native Auth APIs
    (direct API calls, no browser redirect required).

    The script performs:
    1. Authenticates via device code flow
    2. Creates/reuses app registration with nativeAuthenticationApisEnabled
    3. Creates service principal + grants admin consent
    4. Creates user flow (Email+Password + Email OTP)
    5. Links user flow to the app
    6. Updates existing onPasswordSubmit event listener to include this app

.PARAMETER TenantId
    External ID tenant ID where configuration will be applied.

.PARAMETER AppName
    Display name for the Native Auth app registration.
    Default: "JIT Migration Native Auth Client"

.PARAMETER FlowName
    Display name for the user flow.
    Default: "Native Auth JIT Migration Flow"

.PARAMETER MigrationPropertyId
    The extension attribute ID for tracking migration status.
    Format: extension_{ExtensionAppId}_RequiresMigration
    If not provided, the script will look for the existing listener's configuration.

.EXAMPLE
    .\Configure-NativeAuthJit.ps1 -TenantId "c92a6719-2559-47df-baa3-c9f02517c42c"

.EXAMPLE
    .\Configure-NativeAuthJit.ps1 -TenantId "c92a6719-2559-47df-baa3-c9f02517c42c" `
        -AppName "My Native Auth App" `
        -MigrationPropertyId "extension_d7e9bb7927284f7c85d0fa045ec77b1f_RequiresMigration"

.NOTES
    Prerequisites:
    - PowerShell 7.0 or later
    - User must have admin privileges in the External ID tenant
    - The onPasswordSubmit custom authentication extension must already exist
      (run Configure-ExternalIdJit.ps1 first if not)

    Required Permissions (via device code flow):
    - Application.ReadWrite.All
    - EventListener.ReadWrite.All
    - IdentityUserFlow.ReadWrite.All
    - DelegatedPermissionGrant.ReadWrite.All
    - User.Read
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "External ID tenant ID")]
    [string]$TenantId,

    [Parameter(Mandatory = $false)]
    [string]$AppName = "JIT Migration Native Auth Client",

    [Parameter(Mandatory = $false)]
    [string]$FlowName = "Native Auth JIT Migration Flow",

    [Parameter(Mandatory = $false)]
    [string]$MigrationPropertyId
)

$ErrorActionPreference = "Stop"

# ============================================================================
# Helper Functions
# ============================================================================

function Write-Header {
    param([string]$Message)
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  $Message" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""
}

function Write-Success {
    param([string]$Message)
    Write-Host "✓ $Message" -ForegroundColor Green
}

function Write-Info {
    param([string]$Message)
    Write-Host "ℹ $Message" -ForegroundColor Cyan
}

function Write-Step {
    param([string]$Message)
    Write-Host "  → $Message" -ForegroundColor Gray
}

function Write-Warn {
    param([string]$Message)
    Write-Host "⚠ $Message" -ForegroundColor Yellow
}

function Write-ErrorMsg {
    param([string]$Message)
    Write-Host "✗ $Message" -ForegroundColor Red
}

function Invoke-GraphRequest {
    param(
        [string]$Method,
        [string]$Uri,
        [object]$Body,
        [string]$AccessToken
    )

    $headers = @{
        "Authorization" = "Bearer $AccessToken"
        "Content-Type" = "application/json"
    }

    $params = @{
        Method = $Method
        Uri = $Uri
        Headers = $headers
    }

    if ($Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 10)
    }

    try {
        return Invoke-RestMethod @params
    }
    catch {
        if ($_.ErrorDetails.Message) {
            try {
                $errorJson = $_.ErrorDetails.Message | ConvertFrom-Json
                if ($errorJson.error) {
                    Write-ErrorMsg "Graph API: $($errorJson.error.code) - $($errorJson.error.message)"
                }
            } catch {}
        }
        throw
    }
}

function Get-DeviceCodeAccessToken {
    param(
        [string]$TenantId,
        [string[]]$Scopes
    )

    Write-Info "Initiating device code authentication flow..."
    Write-Step "Tenant: $TenantId"

    $clientId = "14d82eec-204b-4c2f-b7e8-296a70dab67e"  # Microsoft Graph Command Line Tools
    $scopeString = ($Scopes -join ' ')

    $deviceCodeResponse = Invoke-RestMethod -Method POST `
        -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/devicecode" `
        -Body @{ client_id = $clientId; scope = $scopeString }

    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Yellow
    Write-Host "  AUTHENTICATION REQUIRED" -ForegroundColor Yellow
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Yellow
    Write-Host ""
    Write-Host $deviceCodeResponse.message -ForegroundColor White
    Write-Host ""

    $timeout = [DateTime]::Now.AddSeconds($deviceCodeResponse.expires_in)
    $interval = $deviceCodeResponse.interval

    while ([DateTime]::Now -lt $timeout) {
        Start-Sleep -Seconds $interval
        try {
            $tokenResponse = Invoke-RestMethod -Method POST `
                -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
                -Body @{
                    grant_type = 'urn:ietf:params:oauth:grant-type:device_code'
                    client_id = $clientId
                    device_code = $deviceCodeResponse.device_code
                }
            Write-Success "Successfully authenticated!"
            return $tokenResponse.access_token
        }
        catch {
            $errorResponse = $_.ErrorDetails.Message | ConvertFrom-Json
            if ($errorResponse.error -eq "authorization_pending") { continue }
            elseif ($errorResponse.error -eq "authorization_declined") { throw "Authentication declined" }
            elseif ($errorResponse.error -eq "expired_token") { throw "Device code expired" }
            else { throw }
        }
    }
    throw "Authentication timeout"
}

# ============================================================================
# Main Script
# ============================================================================

Write-Header "Native Auth + JIT Migration Configuration"

Write-Info "Parameters:"
Write-Step "Tenant ID: $TenantId"
Write-Step "App Name: $AppName"
Write-Step "Flow Name: $FlowName"

# ── Step 1: Authenticate ───────────────────────────────────────────────────────
Write-Header "Step 1: Authentication"

$requiredScopes = @(
    "https://graph.microsoft.com/Application.ReadWrite.All",
    "https://graph.microsoft.com/EventListener.ReadWrite.All",
    "https://graph.microsoft.com/IdentityUserFlow.ReadWrite.All",
    "https://graph.microsoft.com/DelegatedPermissionGrant.ReadWrite.All",
    "https://graph.microsoft.com/User.Read"
)

$accessToken = Get-DeviceCodeAccessToken -TenantId $TenantId -Scopes $requiredScopes

$me = Invoke-GraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/me" -AccessToken $accessToken
Write-Success "Authenticated as: $($me.userPrincipalName)"

# ── Step 2: Create/reuse Native Auth app registration ──────────────────────────
Write-Header "Step 2: Create Native Auth App Registration"

Write-Info "Checking for existing app: $AppName"

$existingApps = Invoke-GraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=displayName eq '$AppName'&`$select=id,appId,displayName,nativeAuthenticationApisEnabled,isFallbackPublicClient" `
    -AccessToken $accessToken

$app = $null
if ($existingApps.value.Count -gt 0) {
    $app = $existingApps.value[0]
    Write-Warn "App already exists - reusing"
    Write-Step "App ID: $($app.appId)"
    Write-Step "Native Auth: $($app.nativeAuthenticationApisEnabled)"

    # Ensure native auth is enabled
    if ($app.nativeAuthenticationApisEnabled -ne "all") {
        Write-Info "Enabling Native Authentication on existing app..."
        Invoke-GraphRequest -Method PATCH `
            -Uri "https://graph.microsoft.com/v1.0/applications/$($app.id)" `
            -Body @{
                nativeAuthenticationApisEnabled = "all"
                isFallbackPublicClient = $true
            } `
            -AccessToken $accessToken
        Write-Success "Native Authentication enabled"
    }
} else {
    Write-Info "Creating app registration: $AppName"
    $appBody = @{
        displayName = $AppName
        signInAudience = "AzureADMyOrg"
        isFallbackPublicClient = $true
        nativeAuthenticationApisEnabled = "all"
        publicClient = @{
            redirectUris = @()
        }
        requiredResourceAccess = @(
            @{
                resourceAppId = "00000003-0000-0000-c000-000000000000"  # Microsoft Graph
                resourceAccess = @(
                    @{ id = "37f7f235-527c-4136-accd-4a02d197296e"; type = "Scope" }  # openid
                    @{ id = "7427e0e9-2fba-42fe-b0c0-848c9e6a8182"; type = "Scope" }  # offline_access
                )
            }
        )
    }

    $app = Invoke-GraphRequest -Method POST `
        -Uri "https://graph.microsoft.com/v1.0/applications" `
        -Body $appBody `
        -AccessToken $accessToken

    Write-Success "App registration created"
    Write-Step "App ID: $($app.appId)"
    Write-Step "Object ID: $($app.id)"
    Write-Step "Native Auth: $($app.nativeAuthenticationApisEnabled)"
}

$nativeAppId = $app.appId
$nativeAppObjectId = $app.id

# ── Step 3: Create service principal + grant admin consent ─────────────────────
Write-Header "Step 3: Service Principal & Admin Consent"

Write-Info "Finding or creating service principal..."
$existingSp = Invoke-GraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$nativeAppId'&`$select=id,appId" `
    -AccessToken $accessToken

$sp = $null
if ($existingSp.value.Count -gt 0) {
    $sp = $existingSp.value[0]
    Write-Success "Service principal exists (ID: $($sp.id))"
} else {
    # Retry with backoff for replication delays
    $maxRetries = 5
    for ($attempt = 1; $attempt -le $maxRetries; $attempt++) {
        try {
            $sp = Invoke-GraphRequest -Method POST `
                -Uri "https://graph.microsoft.com/v1.0/servicePrincipals" `
                -Body @{ appId = $nativeAppId } `
                -AccessToken $accessToken
            Write-Success "Service principal created (ID: $($sp.id))"
            break
        } catch {
            if ($attempt -lt $maxRetries) {
                $wait = $attempt * 5
                Write-Warn "App not yet replicated. Retrying in ${wait}s... ($attempt/$maxRetries)"
                Start-Sleep -Seconds $wait
            } else { throw }
        }
    }
}

# Grant admin consent for openid + offline_access
Write-Info "Granting admin consent for delegated permissions..."
$graphSp = Invoke-GraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '00000003-0000-0000-c000-000000000000'&`$select=id" `
    -AccessToken $accessToken
$graphSpId = $graphSp.value[0].id

$grants = Invoke-GraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($sp.id)/oauth2PermissionGrants" `
    -AccessToken $accessToken
$existingGrant = $grants.value | Where-Object { $_.resourceId -eq $graphSpId -and $_.consentType -eq 'AllPrincipals' }

if ($existingGrant) {
    Write-Success "Admin consent already granted (scope: $($existingGrant.scope))"
} else {
    try {
        Invoke-GraphRequest -Method POST `
            -Uri "https://graph.microsoft.com/v1.0/oauth2PermissionGrants" `
            -Body @{
                clientId = $sp.id
                consentType = "AllPrincipals"
                resourceId = $graphSpId
                scope = "openid offline_access"
            } `
            -AccessToken $accessToken | Out-Null
        Write-Success "Admin consent granted (openid offline_access)"
    } catch {
        Write-Warn "Could not grant admin consent automatically. Grant manually in Azure Portal."
    }
}

# ── Step 4: Create user flow ──────────────────────────────────────────────────
Write-Header "Step 4: Create User Flow"

Write-Info "Checking for existing user flow: $FlowName"
$allFlows = Invoke-GraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/beta/identity/authenticationEventsFlows" `
    -AccessToken $accessToken

$flowId = $null
$matchingFlow = $allFlows.value | Where-Object { $_.displayName -eq $FlowName }
if ($matchingFlow) {
    $flowId = $matchingFlow.id
    Write-Success "Flow already exists (ID: $flowId)"
} else {
    Write-Info "Creating user flow: $FlowName"
    $flowBody = @{
        "@odata.type" = "#microsoft.graph.externalUsersSelfServiceSignUpEventsFlow"
        displayName = $FlowName
        onAuthenticationMethodLoadStart = @{
            "@odata.type" = "#microsoft.graph.onAuthenticationMethodLoadStartExternalUsersSelfServiceSignUp"
            identityProviders = @(
                @{ id = "EmailPassword-OAUTH" }
                @{ id = "EmailOtpSignup-OAUTH" }
            )
        }
        onInteractiveAuthFlowStart = @{
            "@odata.type" = "#microsoft.graph.onInteractiveAuthFlowStartExternalUsersSelfServiceSignUp"
            isSignUpAllowed = $true
        }
        onAttributeCollection = @{
            "@odata.type" = "#microsoft.graph.onAttributeCollectionExternalUsersSelfServiceSignUp"
            attributes = @(
                @{ id = "email" }
                @{ id = "displayName" }
            )
            attributeCollectionPage = @{
                views = @(@{
                    inputs = @(
                        @{ attribute = "email"; label = "Email"; required = $true }
                        @{ attribute = "displayName"; label = "Display Name"; required = $true }
                    )
                })
            }
        }
    }

    try {
        $flow = Invoke-GraphRequest -Method POST `
            -Uri "https://graph.microsoft.com/beta/identity/authenticationEventsFlows" `
            -Body $flowBody `
            -AccessToken $accessToken
        $flowId = $flow.id
        Write-Success "Flow created (ID: $flowId)"
    } catch {
        $errBody = $null
        try { $errBody = $_.ErrorDetails.Message | ConvertFrom-Json } catch {}
        if ($errBody.error.message -match "displayName is in use by AuthenticationEventsFlow with id '([^']+)'") {
            $flowId = $Matches[1]
            Write-Success "Flow already exists (ID: $flowId)"
        } else { throw }
    }
}

# ── Step 5: Link flow to app ─────────────────────────────────────────────────
Write-Header "Step 5: Link User Flow to App"

Write-Info "Checking if flow is linked to application..."
$linkedApps = Invoke-GraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/beta/identity/authenticationEventsFlows/$flowId/conditions/applications/includeApplications" `
    -AccessToken $accessToken

$alreadyLinked = ($linkedApps.value | Where-Object { $_.appId -eq $nativeAppId }).Count -gt 0

if ($alreadyLinked) {
    Write-Success "Flow is already linked to app"
} else {
    Write-Info "Linking flow to application..."
    Invoke-GraphRequest -Method POST `
        -Uri "https://graph.microsoft.com/beta/identity/authenticationEventsFlows/$flowId/conditions/applications/includeApplications" `
        -Body @{
            "@odata.type" = "#microsoft.graph.authenticationConditionApplication"
            appId = $nativeAppId
        } `
        -AccessToken $accessToken | Out-Null
    Write-Success "Flow linked to application"
}

# ── Step 6: Update event listener to include Native Auth app ──────────────────
Write-Header "Step 6: Update Event Listener"

Write-Info "Finding existing onPasswordSubmit event listener..."
$listeners = Invoke-GraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/beta/identity/authenticationEventListeners" `
    -AccessToken $accessToken

$passwordListeners = @($listeners.value | Where-Object {
    $_.'@odata.type' -eq '#microsoft.graph.onPasswordSubmitListener'
})

if ($passwordListeners.Count -eq 0) {
    Write-ErrorMsg "No onPasswordSubmit listener found!"
    Write-Info "Run Configure-ExternalIdJit.ps1 first to create the JIT configuration."
    exit 1
}

# Use the first listener (most recently relevant)
$passwordListener = $passwordListeners[0]
Write-Success "Found listener: $($passwordListener.id)"
if ($passwordListeners.Count -gt 1) {
    Write-Warn "Multiple onPasswordSubmit listeners found ($($passwordListeners.Count)). Using first: $($passwordListener.id)"
}

# Check if Native Auth app is already included
$currentApps = $passwordListener.conditions.applications.includeApplications
$alreadyIncluded = ($currentApps | Where-Object { $_.appId -eq $nativeAppId }).Count -gt 0

if ($alreadyIncluded) {
    Write-Success "Native Auth app already included in event listener"
} else {
    Write-Info "Adding Native Auth app to event listener..."

    # Try adding via POST to includeApplications collection (preferred approach)
    try {
        Invoke-GraphRequest -Method POST `
            -Uri "https://graph.microsoft.com/beta/identity/authenticationEventListeners/$($passwordListener.id)/conditions/applications/includeApplications" `
            -Body @{
                "@odata.type" = "#microsoft.graph.authenticationConditionApplication"
                appId = $nativeAppId
            } `
            -AccessToken $accessToken | Out-Null
        Write-Success "Event listener updated - Native Auth app added"
    } catch {
        # Fallback: try PATCH on the listener itself
        Write-Warn "POST failed, trying PATCH approach..."
        $updatedApps = @($currentApps | ForEach-Object { @{ appId = $_.appId } })
        $updatedApps += @{ appId = $nativeAppId }

        try {
            Invoke-GraphRequest -Method PATCH `
                -Uri "https://graph.microsoft.com/beta/identity/authenticationEventListeners/$($passwordListener.id)" `
                -Body @{
                    conditions = @{
                        applications = @{
                            includeAllApplications = $false
                            includeApplications = $updatedApps
                        }
                    }
                } `
                -AccessToken $accessToken | Out-Null
            Write-Success "Event listener updated via PATCH - Native Auth app added"
        } catch {
            Write-ErrorMsg "Failed to update listener automatically."
            Write-Warn "Please add app manually in Azure Portal:"
            Write-Step "Entra Admin Center → External Identities → Custom auth extensions"
            Write-Step "→ Event listeners → $($passwordListener.id)"
            Write-Step "→ Add application: $nativeAppId"
            Write-Info "Listener ID: $($passwordListener.id)"
            Write-Info "Native Auth App ID: $nativeAppId"
        }
    }
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-Header "Configuration Complete!"

# Derive tenant subdomain
$tenantInfo = Invoke-GraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/organization?`$select=verifiedDomains" `
    -AccessToken $accessToken
$tenantDomain = ($tenantInfo.value[0].verifiedDomains | Where-Object { $_.name -like "*.onmicrosoft.com" -and $_.name -notlike "*mail*" }).name
$tenantSubdomain = $tenantDomain -replace '\.onmicrosoft\.com$', ''

Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  NATIVE AUTH JIT CONFIGURATION SUMMARY" -ForegroundColor Green
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host ""
Write-Host "Native Auth App:" -ForegroundColor Cyan
Write-Step "App ID (Client ID): $nativeAppId"
Write-Step "Object ID: $nativeAppObjectId"
Write-Step "Native Auth Enabled: all"
Write-Host ""
Write-Host "User Flow:" -ForegroundColor Cyan
Write-Step "Flow ID: $flowId"
Write-Step "Flow Name: $FlowName"
Write-Host ""
Write-Host "Event Listener:" -ForegroundColor Cyan
Write-Step "Listener ID: $($passwordListener.id)"
Write-Step "Apps Included: includes $nativeAppId"
Write-Host ""
Write-Host "Tenant:" -ForegroundColor Cyan
Write-Step "Subdomain: $tenantSubdomain"
Write-Step "Domain: $tenantDomain"
Write-Host ""

Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Yellow
Write-Host "  TEST WITH:" -ForegroundColor Yellow
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Yellow
Write-Host ""
Write-Host "  .\Test-NativeAuthJit.ps1 ``" -ForegroundColor White
Write-Host "      -TenantSubdomain `"$tenantSubdomain`" ``" -ForegroundColor White
Write-Host "      -ClientId `"$nativeAppId`" ``" -ForegroundColor White
Write-Host "      -Username `"testjit1@slider-inc.com`" ``" -ForegroundColor White
Write-Host "      -Password `"TempP@ssw0rd!2026`"" -ForegroundColor White
Write-Host ""

# Set env vars for convenience
$env:NATIVE_AUTH_APP_ID = $nativeAppId
$env:NATIVE_AUTH_TENANT = $tenantSubdomain
Write-Info "Environment variables set: NATIVE_AUTH_APP_ID, NATIVE_AUTH_TENANT"
Write-Host ""
