# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
<#
.SYNOPSIS
    Configures Microsoft Entra External ID for Just-In-Time (JIT) password migration.

.DESCRIPTION
    This script automates the configuration of app registrations, custom authentication extensions,
    and event listeners in Microsoft Entra External ID to enable JIT password migration.
    
    The script performs the following steps:
    1. Authenticates using device code flow (assumes admin privileges)
    2. Creates/configures custom authentication extension app registration
    3. Exports and configures encryption certificate public key
    4. Creates custom extension policy
    5. Creates client application for testing
    6. Creates event listener policy
    
    This follows the official Microsoft documentation for External ID JIT migration.

.PARAMETER TenantId
    The External ID tenant ID where the configuration will be applied.

.PARAMETER CertificatePath
    Path to the certificate file (.cer format) for encrypting password payloads.
    This should be exported from your Key Vault (JitMigrationEncryptionCert).

.PARAMETER FunctionUrl
    The URL of your Azure Function endpoint for JIT authentication.
    Example: https://contoso.azurewebsites.net/api/JitAuthentication

.PARAMETER ExtensionAppName
    Name for the custom authentication extension app registration.
    Default: "EEID Auth Extension - JIT Migration"

.PARAMETER ClientAppName
    Name for the test client application.
    Default: "JIT Migration Test Client"

.PARAMETER MigrationPropertyId
    The extension attribute ID for tracking migration status.
    Format: extension_{ExtensionAppId}_RequiresMigration
    If not provided, you'll be prompted to enter it.

.PARAMETER SkipClientApp
    Skip creating the test client application if it already exists.

.EXAMPLE
    .\Configure-ExternalIdJit.ps1 -TenantId "your-tenant-id" `
        -CertificatePath "C:\certs\jitmigrationencryptioncert.cer" `
        -FunctionUrl "https://contoso.azurewebsites.net/api/JitAuthentication" `
        -MigrationPropertyId "extension_12345678_RequiresMigration"
    
    Configures External ID for JIT migration with the specified parameters.

.EXAMPLE
    .\Configure-ExternalIdJit.ps1 -TenantId "your-tenant-id" `
        -CertificatePath ".\cert.cer" `
        -FunctionUrl "https://contoso.azurewebsites.net/api/JitAuthentication" `
        -SkipClientApp
    
    Configures External ID but skips client app creation.

.NOTES
    Prerequisites:
    - PowerShell 7.0 or later
    - User must have admin privileges in the External ID tenant
    - Certificate must be exported from Key Vault in CER format
    - Azure Function must be deployed and accessible
    
    Required Permissions (granted during device code flow):
    - Application.ReadWrite.All
    - CustomAuthenticationExtension.ReadWrite.All
    - User.Read
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "External ID tenant ID")]
    [string]$TenantId,

    [Parameter(Mandatory = $true, HelpMessage = "Path to certificate file (.cer format)")]
    [ValidateScript({
        if (Test-Path $_) { $true }
        else { throw "Certificate file not found: $_" }
    })]
    [string]$CertificatePath,

    [Parameter(Mandatory = $true, HelpMessage = "Azure Function URL for JIT authentication")]
    [ValidatePattern('^https://.*')]
    [string]$FunctionUrl,

    [Parameter(Mandatory = $false)]
    [string]$ExtensionAppName = "EEID Auth Extension - JIT Migration",

    [Parameter(Mandatory = $false)]
    [string]$ClientAppName = "JIT Migration Test Client",

    [Parameter(Mandatory = $false)]
    [string]$MigrationPropertyId,

    [Parameter(Mandatory = $false)]
    [switch]$SkipClientApp
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

function Write-Warning {
    param([string]$Message)
    Write-Host "⚠ $Message" -ForegroundColor Yellow
}

function Write-ErrorMsg {
    param([string]$Message)
    Write-Host "✗ $Message" -ForegroundColor Red
}

function Invoke-GraphRequest {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Method,
        
        [Parameter(Mandatory = $true)]
        [string]$Uri,
        
        [Parameter(Mandatory = $false)]
        [object]$Body,
        
        [Parameter(Mandatory = $true)]
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
        $response = Invoke-RestMethod @params
        return $response
    }
    catch {
        Write-ErrorMsg "Graph API request failed: $($_.Exception.Message)"
        if ($_.Exception.Response) {
            $reader = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream())
            $responseBody = $reader.ReadToEnd()
            Write-Host "Response: $responseBody" -ForegroundColor Red
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
    Write-Step "Scopes: $($Scopes -join ', ')"
    Write-Host ""
    
    # Request device code
    $clientId = "14d82eec-204b-4c2f-b7e8-296a70dab67e"  # Microsoft Graph Command Line Tools
    $scopeString = ($Scopes -join ' ')
    
    $deviceCodeParams = @{
        Method = 'POST'
        Uri = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/devicecode"
        Body = @{
            client_id = $clientId
            scope = $scopeString
        }
    }
    
    try {
        $deviceCodeResponse = Invoke-RestMethod @deviceCodeParams
    }
    catch {
        Write-ErrorMsg "Failed to get device code: $($_.Exception.Message)"
        throw
    }
    
    # Display device code instructions
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Yellow
    Write-Host "  AUTHENTICATION REQUIRED" -ForegroundColor Yellow
    Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Yellow
    Write-Host ""
    Write-Host $deviceCodeResponse.message -ForegroundColor White
    Write-Host ""
    Write-Host "Waiting for authentication..." -ForegroundColor Gray
    Write-Host ""
    
    # Poll for token
    $tokenParams = @{
        Method = 'POST'
        Uri = "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token"
        Body = @{
            grant_type = 'urn:ietf:params:oauth:grant-type:device_code'
            client_id = $clientId
            device_code = $deviceCodeResponse.device_code
        }
    }
    
    $timeout = [DateTime]::Now.AddSeconds($deviceCodeResponse.expires_in)
    $interval = $deviceCodeResponse.interval
    
    while ([DateTime]::Now -lt $timeout) {
        Start-Sleep -Seconds $interval
        
        try {
            $tokenResponse = Invoke-RestMethod @tokenParams
            Write-Success "Successfully authenticated!"
            Write-Host ""
            return $tokenResponse.access_token
        }
        catch {
            $errorResponse = $_.ErrorDetails.Message | ConvertFrom-Json
            if ($errorResponse.error -eq "authorization_pending") {
                # Still waiting for user to authenticate
                continue
            }
            elseif ($errorResponse.error -eq "authorization_declined") {
                Write-ErrorMsg "Authentication was declined by user"
                throw "Authentication declined"
            }
            elseif ($errorResponse.error -eq "expired_token") {
                Write-ErrorMsg "Device code expired"
                throw "Device code expired"
            }
            else {
                Write-ErrorMsg "Token request failed: $($errorResponse.error_description)"
                throw
            }
        }
    }
    
    Write-ErrorMsg "Authentication timed out"
    throw "Authentication timeout"
}

# ============================================================================
# Main Script
# ============================================================================

Write-Header "External ID JIT Migration Configuration"

Write-Info "Configuration Parameters:"
Write-Step "Tenant ID: $TenantId"
Write-Step "Certificate: $CertificatePath"
Write-Step "Function URL: $FunctionUrl"
Write-Step "Extension App: $ExtensionAppName"
if (-not $SkipClientApp) {
    Write-Step "Client App: $ClientAppName"
}
Write-Host ""

# Step 0: Authenticate using device code flow
Write-Header "Step 1: Authentication"

$requiredScopes = @(
    "https://graph.microsoft.com/Application.ReadWrite.All",
    "https://graph.microsoft.com/CustomAuthenticationExtension.ReadWrite.All",
    "https://graph.microsoft.com/User.Read"
)

$accessToken = Get-DeviceCodeAccessToken -TenantId $TenantId -Scopes $requiredScopes

# Verify authentication by getting current user
try {
    $me = Invoke-GraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/me" -AccessToken $accessToken
    Write-Success "Authenticated as: $($me.userPrincipalName)"
    Write-Host ""
}
catch {
    Write-ErrorMsg "Failed to verify authentication"
    exit 1
}

# Step 1: Create or update custom authentication extension app registration
Write-Header "Step 2: Configure Custom Authentication Extension App"

Write-Info "Creating app registration: $ExtensionAppName"

# Check if app already exists
$existingApps = Invoke-GraphRequest -Method GET `
    -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=displayName eq '$ExtensionAppName'" `
    -AccessToken $accessToken

if ($existingApps.value.Count -gt 0) {
    Write-Warning "App registration already exists"
    $app = $existingApps.value[0]
    Write-Step "Using existing app: $($app.appId)"
} else {
    # Create new app registration
    $appBody = @{
        displayName = $ExtensionAppName
        signInAudience = "AzureADMyOrg"
        requiredResourceAccess = @(
            @{
                resourceAppId = "00000003-0000-0000-c000-000000000000"  # Microsoft Graph
                resourceAccess = @(
                    @{
                        id = "214e810f-fda8-4fd7-a475-29461495eb00"  # CustomAuthenticationExtension.Receive.Payload
                        type = "Role"
                    }
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
}

$extensionAppId = $app.appId
$extensionAppObjectId = $app.id

# Extract hostname from Function URL
$functionUri = [System.Uri]$FunctionUrl
$functionHostname = $functionUri.Host

# Configure identifier URI
Write-Info "Configuring identifier URI..."
$identifierUri = "api://$functionHostname/$extensionAppId"

$updateAppBody = @{
    identifierUris = @($identifierUri)
}

Invoke-GraphRequest -Method PATCH `
    -Uri "https://graph.microsoft.com/v1.0/applications/$extensionAppObjectId" `
    -Body $updateAppBody `
    -AccessToken $accessToken

Write-Success "Identifier URI configured: $identifierUri"

# Grant admin consent for API permissions
Write-Info "Granting admin consent for API permissions..."
Write-Warning "Please grant admin consent manually in the Azure Portal:"
Write-Step "Navigate to: Azure Portal → App registrations → $ExtensionAppName"
Write-Step "Go to: API permissions → Grant admin consent for [Your Tenant]"
Write-Host ""
$consent = Read-Host "Press Enter after granting admin consent (or 's' to skip)"
if ($consent -ne 's') {
    Write-Success "Admin consent confirmed"
}

# Step 2: Configure encryption certificate
Write-Header "Step 3: Configure Encryption Certificate"

Write-Info "Loading certificate from: $CertificatePath"

try {
    $cert = New-Object System.Security.Cryptography.X509Certificates.X509Certificate2($CertificatePath)
    $certBase64 = [Convert]::ToBase64String($cert.RawData)
    Write-Success "Certificate loaded successfully"
    Write-Step "Subject: $($cert.Subject)"
    Write-Step "Valid from: $($cert.NotBefore)"
    Write-Step "Valid to: $($cert.NotAfter)"
}
catch {
    Write-ErrorMsg "Failed to load certificate: $($_.Exception.Message)"
    exit 1
}

# Generate a new GUID for the key
$keyGuid = [guid]::NewGuid().ToString()

Write-Info "Configuring encryption key on app registration..."

$keyCredentialsBody = @{
    keyCredentials = @(
        @{
            endDateTime = $cert.NotAfter.ToString("yyyy-MM-ddTHH:mm:ssZ")
            keyId = $keyGuid
            startDateTime = $cert.NotBefore.ToString("yyyy-MM-ddTHH:mm:ssZ")
            type = "AsymmetricX509Cert"
            usage = "Encrypt"
            key = $certBase64
            displayName = "CN=JitMigration"
        }
    )
    tokenEncryptionKeyId = $keyGuid
}

Invoke-GraphRequest -Method PATCH `
    -Uri "https://graph.microsoft.com/v1.0/applications/$extensionAppObjectId" `
    -Body $keyCredentialsBody `
    -AccessToken $accessToken

Write-Success "Encryption certificate configured"
Write-Step "Key ID: $keyGuid"

# Step 3: Create custom extension policy
Write-Header "Step 4: Create Custom Authentication Extension Policy"

Write-Info "Creating custom authentication extension..."

$extensionBody = @{
    "@odata.type" = "#microsoft.graph.onPasswordSubmitCustomExtension"
    displayName = "OnPasswordSubmitCustomExtension"
    description = "Validate password"
    endpointConfiguration = @{
        "@odata.type" = "#microsoft.graph.httpRequestEndpoint"
        targetUrl = $FunctionUrl
    }
    authenticationConfiguration = @{
        "@odata.type" = "#microsoft.graph.azureAdTokenAuthentication"
        resourceId = $identifierUri
    }
    clientConfiguration = @{
        timeoutInMilliseconds = 2000
        maximumRetries = 1
    }
}

try {
    $customExtension = Invoke-GraphRequest -Method POST `
        -Uri "https://graph.microsoft.com/beta/identity/customAuthenticationExtensions" `
        -Body $extensionBody `
        -AccessToken $accessToken
    
    Write-Success "Custom authentication extension created"
    Write-Step "Extension ID: $($customExtension.id)"
    $customExtensionId = $customExtension.id
}
catch {
    Write-ErrorMsg "Failed to create custom extension"
    Write-Info "Checking if extension already exists..."
    
    $existingExtensions = Invoke-GraphRequest -Method GET `
        -Uri "https://graph.microsoft.com/beta/identity/customAuthenticationExtensions" `
        -AccessToken $accessToken
    
    $matchingExtension = $existingExtensions.value | Where-Object { $_.displayName -eq "OnPasswordSubmitCustomExtension" }
    
    if ($matchingExtension) {
        Write-Warning "Using existing custom extension"
        $customExtensionId = $matchingExtension.id
        Write-Step "Extension ID: $customExtensionId"
        
        # Update the existing extension
        Write-Info "Updating custom extension configuration..."
        Invoke-GraphRequest -Method PATCH `
            -Uri "https://graph.microsoft.com/beta/identity/customAuthenticationExtensions/$customExtensionId" `
            -Body $extensionBody `
            -AccessToken $accessToken
        Write-Success "Custom extension updated"
    }
    else {
        throw
    }
}

# Step 4: Create client application for testing
if (-not $SkipClientApp) {
    Write-Header "Step 5: Create Test Client Application"
    
    Write-Info "Creating client app registration: $ClientAppName"
    
    # Check if client app already exists
    $existingClientApps = Invoke-GraphRequest -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=displayName eq '$ClientAppName'" `
        -AccessToken $accessToken
    
    if ($existingClientApps.value.Count -gt 0) {
        Write-Warning "Client app already exists"
        $clientApp = $existingClientApps.value[0]
        Write-Step "Using existing app: $($clientApp.appId)"
    } else {
        $clientAppBody = @{
            displayName = $ClientAppName
            signInAudience = "AzureADMyOrg"
            web = @{
                redirectUris = @("https://jwt.ms")
                implicitGrantSettings = @{
                    enableIdTokenIssuance = $true
                }
            }
            requiredResourceAccess = @(
                @{
                    resourceAppId = "00000003-0000-0000-c000-000000000000"  # Microsoft Graph
                    resourceAccess = @(
                        @{
                            id = "e1fe6dd8-ba31-4d61-89e7-88639da4683d"  # User.Read
                            type = "Scope"
                        }
                    )
                }
            )
        }
        
        $clientApp = Invoke-GraphRequest -Method POST `
            -Uri "https://graph.microsoft.com/v1.0/applications" `
            -Body $clientAppBody `
            -AccessToken $accessToken
        
        Write-Success "Client app created"
        Write-Step "App ID: $($clientApp.appId)"
        Write-Step "Object ID: $($clientApp.id)"
        Write-Step "Redirect URI: https://jwt.ms"
    }
    
    $clientAppId = $clientApp.appId
    
    Write-Info "Granting admin consent for User.Read..."
    Write-Warning "Please grant admin consent manually in the Azure Portal:"
    Write-Step "Navigate to: Azure Portal → App registrations → $ClientAppName"
    Write-Step "Go to: API permissions → Grant admin consent for [Your Tenant]"
    Write-Host ""
    $consent = Read-Host "Press Enter after granting admin consent (or 's' to skip)"
    if ($consent -ne 's') {
        Write-Success "Admin consent confirmed"
    }
} else {
    Write-Header "Step 5: Skipping Client Application Creation"
    Write-Info "You can create a client app later or use an existing one"
    
    # Prompt for existing client app ID
    Write-Host ""
    $clientAppId = Read-Host "Enter the client app ID for listener configuration (or press Enter to skip listener creation)"
    
    if ([string]::IsNullOrWhiteSpace($clientAppId)) {
        Write-Warning "Skipping listener creation - no client app ID provided"
        $skipListener = $true
    }
}

# Step 5: Create event listener policy
if (-not $skipListener) {
    Write-Header "Step 6: Create Event Listener Policy"
    
    # Prompt for migration property ID if not provided
    if ([string]::IsNullOrWhiteSpace($MigrationPropertyId)) {
        Write-Host ""
        Write-Info "Migration property ID is required for the event listener"
        Write-Step "Format: extension_{ExtensionAppId}_RequiresMigration"
        Write-Step "Example: extension_12345678901234567890123456789012_RequiresMigration"
        Write-Host ""
        $MigrationPropertyId = Read-Host "Enter the migration property ID"
        
        if ([string]::IsNullOrWhiteSpace($MigrationPropertyId)) {
            Write-ErrorMsg "Migration property ID is required"
            exit 1
        }
    }
    
    Write-Info "Creating event listener for client app: $clientAppId"
    Write-Step "Migration property: $MigrationPropertyId"
    
    $listenerBody = @{
        "@odata.type" = "#microsoft.graph.onPasswordSubmitListener"
        conditions = @{
            applications = @{
                includeAllApplications = $false
                includeApplications = @(
                    @{
                        appId = $clientAppId
                    }
                )
            }
        }
        priority = 500
        handler = @{
            "@odata.type" = "#microsoft.graph.onPasswordMigrationCustomExtensionHandler"
            migrationPropertyId = $MigrationPropertyId
            customExtension = @{
                id = $customExtensionId
            }
        }
    }
    
    try {
        $listener = Invoke-GraphRequest -Method POST `
            -Uri "https://graph.microsoft.com/beta/identity/authenticationEventListeners" `
            -Body $listenerBody `
            -AccessToken $accessToken
        
        Write-Success "Event listener created"
        Write-Step "Listener ID: $($listener.id)"
    }
    catch {
        Write-ErrorMsg "Failed to create event listener"
        Write-Info "You may need to create the listener manually or update an existing one"
        Write-Step "Client App ID: $clientAppId"
        Write-Step "Custom Extension ID: $customExtensionId"
        Write-Step "Migration Property: $MigrationPropertyId"
    }
}

# Summary
Write-Header "Configuration Complete!"

Write-Success "JIT Migration has been configured successfully"
Write-Host ""

Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host "  CONFIGURATION SUMMARY" -ForegroundColor Green
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Green
Write-Host ""
Write-Host "Custom Extension App:" -ForegroundColor Cyan
Write-Step "App ID: $extensionAppId"
Write-Step "Object ID: $extensionAppObjectId"
Write-Step "Identifier URI: $identifierUri"
Write-Host ""
Write-Host "Custom Authentication Extension:" -ForegroundColor Cyan
Write-Step "Extension ID: $customExtensionId"
Write-Step "Target URL: $FunctionUrl"
Write-Host ""
if (-not $SkipClientApp -and $clientAppId) {
    Write-Host "Test Client App:" -ForegroundColor Cyan
    Write-Step "App ID: $clientAppId"
    Write-Step "Redirect URI: https://jwt.ms"
    Write-Host ""
}
if (-not $skipListener) {
    Write-Host "Event Listener:" -ForegroundColor Cyan
    Write-Step "Migration Property: $MigrationPropertyId"
    Write-Step "Client App ID: $clientAppId"
    Write-Host ""
}

Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Yellow
Write-Host "  NEXT STEPS" -ForegroundColor Yellow
Write-Host "═══════════════════════════════════════════════════════════════" -ForegroundColor Yellow
Write-Host ""
Write-Host "1. Verify Azure Function Configuration:" -ForegroundColor White
Write-Step "Ensure the Function App has the correct settings for JIT authentication"
Write-Step "Verify the Function App can access the private key from Key Vault"
Write-Host ""
Write-Host "2. Test the Configuration:" -ForegroundColor White
Write-Step "Navigate to: https://jwt.ms"
Write-Step "Sign in with a user that has the migration flag set"
Write-Step "Verify the JIT function is called and password is validated"
Write-Host ""
Write-Host "3. Monitor and Validate:" -ForegroundColor White
Write-Step "Check Azure Function logs for successful password validation"
Write-Step "Verify user migration status is updated after first login"
Write-Step "Monitor Application Insights for errors or issues"
Write-Host ""
Write-Host "4. Before Production Deployment:" -ForegroundColor White
Write-Step "Test with multiple user accounts"
Write-Step "Verify error handling and retry logic"
Write-Step "Ensure all security requirements are met"
Write-Step "Review and test the rollback plan"
Write-Host ""

Write-Info "For detailed documentation, see: https://learn.microsoft.com/entra/external-id"
Write-Host ""
