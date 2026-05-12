# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
<#
.SYNOPSIS
    Creates a B2C API Connector + Sign-up/Sign-in user flow wired together for
    local endpoint testing.

.DESCRIPTION
    Authenticates to the B2C tenant via device code flow, then:
      1. Creates (or reuses) an API Connector pointing to the local devtunnel URL.
      2. Creates (or reuses) a B2C_1_SignUpSignIn_ConnectorTest user flow.
      3. Attaches the connector to the postFederationSignup step.

    The connector uses Basic Auth where the password equals -ApiKey.
    The ApiConnectorTestFunction accepts this automatically.

.PARAMETER TenantId
    B2C tenant ID or domain (e.g. contoso.onmicrosoft.com).
    Defaults to the value in src/B2CMigrationKit.Function/local.settings.json.

.PARAMETER ConnectorUrl
    Public URL of the ApiConnectorTest endpoint
    (e.g. https://1vgs2hr5-7071.brs.devtunnels.ms/api/ApiConnectorTest).

.PARAMETER ApiKey
    API key the connector will send as the Basic Auth password.
    Default: test-api-key-change-me

.PARAMETER FlowName
    Short name for the user flow (B2C_1_ prefix added automatically).
    Default: SignUpSignIn_ConnectorTest

.PARAMETER ConnectorStep
    Which step to attach the connector to.
    Valid values: PostFederationSignup, PostAttributeCollection
    Default: PostFederationSignup

.EXAMPLE
    .\New-B2CTestFlow.ps1 `
        -TenantId "SliderInc.onmicrosoft.com" `
        -ConnectorUrl "https://1vgs2hr5-7071.brs.devtunnels.ms/api/ApiConnectorTest"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$TenantId,

    [Parameter(Mandatory = $true)]
    [string]$ConnectorUrl,

    [Parameter(Mandatory = $false)]
    [string]$ApiKey = "test-api-key-change-me",

    [Parameter(Mandatory = $false)]
    [string]$FlowName = "SignUpSignIn_ConnectorTest",

    [Parameter(Mandatory = $false)]
    [ValidateSet("PostFederationSignup", "PostAttributeCollection", "PreTokenIssuance")]
    [string]$ConnectorStep = "PreTokenIssuance"
)

$ErrorActionPreference = "Stop"
. (Join-Path $PSScriptRoot "_Common.ps1")

# ── Resolve TenantId from local.settings.json if not provided ─────────────────
if (-not $TenantId) {
    $settingsPath = Join-Path $PSScriptRoot "..\src\B2CMigrationKit.Function\local.settings.json"
    if (Test-Path $settingsPath) {
        $settings = Get-Content $settingsPath -Raw | ConvertFrom-Json
        $TenantId = $settings.Values.'Migration__B2C__TenantId'
        $domain   = $settings.Values.'Migration__B2C__TenantDomain'
        Write-Info "Using B2C tenant from local.settings.json: $domain ($TenantId)"
    }
    else {
        Write-Err "TenantId not provided and local.settings.json not found."
        exit 1
    }
}

$fullFlowId = "B2C_1_$FlowName"

Write-SectionHeader "New B2C Test Flow"
Write-Info "Tenant:          $TenantId"
Write-Info "Connector URL:   $ConnectorUrl"
Write-Info "User flow:       $fullFlowId"
Write-Info "Step:            $ConnectorStep"
Write-Host ""

# ── Authenticate ──────────────────────────────────────────────────────────────
Write-SubHeader "Step 1 · Authenticate to B2C"
$token = Get-DeviceCodeToken -TenantId $TenantId -TenantLabel "B2C" -Scopes @(
    "https://graph.microsoft.com/APIConnectors.ReadWrite.All",
    "https://graph.microsoft.com/IdentityUserFlow.ReadWrite.All"
)
$headers = @{ Authorization = "Bearer $token" }

# ── Create / reuse API Connector ──────────────────────────────────────────────
Write-SubHeader "Step 2 · API Connector"

$connectorName = "LocalDevTest - ApiConnectorTest"

$existing = Invoke-GraphAllPages `
    -Uri "https://graph.microsoft.com/v1.0/identity/apiConnectors" `
    -Headers $headers
$connector = $existing | Where-Object { $_.displayName -eq $connectorName } | Select-Object -First 1

if ($connector) {
    Write-Warn "  Connector already exists → $($connector.id)"
    Write-Info "  Updating targetUrl to: $ConnectorUrl"

    Invoke-Graph -Method PATCH `
        -Uri "https://graph.microsoft.com/v1.0/identity/apiConnectors/$($connector.id)" `
        -Headers $headers `
        -Body @{
            targetUrl                = $ConnectorUrl
            authenticationConfiguration = @{
                "@odata.type" = "#microsoft.graph.basicAuthentication"
                username      = "b2ctest"
                password      = $ApiKey
            }
        } | Out-Null

    Write-Success "  Updated → $($connector.id)"
}
else {
    $connectorBody = @{
        displayName              = $connectorName
        targetUrl                = $ConnectorUrl
        authenticationConfiguration = @{
            "@odata.type" = "#microsoft.graph.basicAuthentication"
            username      = "b2ctest"
            password      = $ApiKey
        }
    }

    $connector = Invoke-Graph -Method POST `
        -Uri "https://graph.microsoft.com/v1.0/identity/apiConnectors" `
        -Headers $headers -Body $connectorBody

    Write-Success "  Created connector → $($connector.id)"
}

# ── Create / reuse user flow ───────────────────────────────────────────────────
Write-SubHeader "Step 3 · User Flow"

$flowsUri = "https://graph.microsoft.com/beta/identity/b2cUserFlows?`$select=id,userFlowType"
$flows    = Invoke-GraphAllPages -Uri $flowsUri -Headers $headers
$flow     = $flows | Where-Object { $_.id -eq $fullFlowId } | Select-Object -First 1

if ($flow) {
    Write-Warn "  User flow already exists → $fullFlowId"
}
else {
    $flowBody = @{
        id                  = $FlowName   # B2C prepends B2C_1_ automatically
        userFlowType        = "signUpOrSignIn"
        userFlowTypeVersion = 3
    }

    $flow = Invoke-Graph -Method POST `
        -Uri "https://graph.microsoft.com/beta/identity/b2cUserFlows" `
        -Headers $headers -Body $flowBody

    Write-Success "  Created user flow → $($flow.id)"

    # Small delay so the flow is fully provisioned before attaching the connector
    Start-Sleep -Seconds 3
}

# ── Attach connector to user flow step ────────────────────────────────────────
Write-SubHeader "Step 4 · Attach Connector to $ConnectorStep"

# Map friendly name to Graph API property name
$stepKeyMap = @{
    PostFederationSignup    = 'postFederationSignup'
    PostAttributeCollection = 'postAttributeCollection'
    PreTokenIssuance        = 'preSendingClaims'
}
$stepKey    = $stepKeyMap[$ConnectorStep]
$refBody    = @{ "@odata.id" = "https://graph.microsoft.com/beta/identity/apiConnectors/$($connector.id)" }
$refUri     = "https://graph.microsoft.com/beta/identity/b2cUserFlows/$fullFlowId/apiConnectorConfiguration/$stepKey/`$ref"

try {
    Invoke-Graph -Method PUT -Uri $refUri -Headers $headers -Body $refBody | Out-Null
    Write-Success "  Connector attached to $ConnectorStep"
}
catch {
    # 409 Conflict means it's already attached — not an error
    if ($_.Exception.Message -like '*409*' -or $_.Exception.Message -like '*Conflict*') {
        Write-Warn "  Connector already attached to $ConnectorStep (skipped)"
    }
    else {
        throw
    }
}

# ── Summary ───────────────────────────────────────────────────────────────────
Write-SectionHeader "Done" -Color Green
Write-Host ""
Write-Host "  User flow:   $fullFlowId" -ForegroundColor Yellow
Write-Host "  Connector:   $connectorName" -ForegroundColor Yellow
Write-Host "  Step:        $ConnectorStep" -ForegroundColor Yellow
Write-Host "  Endpoint:    $ConnectorUrl" -ForegroundColor Yellow
Write-Host ""
Write-Info "Next steps:"
Write-Info "  1. Azure Portal → B2C → User flows → $fullFlowId → Run user flow"
Write-Info "  2. Sign up a new user and watch the function logs for the incoming payload"
Write-Info "  3. Verify the response claims appear in the token at https://jwt.ms"
Write-Host ""
