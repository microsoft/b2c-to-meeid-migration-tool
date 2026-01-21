# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet("Local", "Azure")]
    [string]$Environment,
    
    [Parameter(Mandatory = $true)]
    [string]$TenantId,
    
    [Parameter(Mandatory = $true)]
    [string]$ExtensionId,
    
    [string]$LocalAppObjectId,
    [string]$LocalAppId,
    [string]$NgrokDomain,
    [string]$AzureFunctionUrl,
    [string]$AzureAppObjectId,
    [string]$AzureAppId
)

$ErrorActionPreference = "Stop"

function Write-Success { Write-Host $args -ForegroundColor Green }
function Write-Info { Write-Host $args -ForegroundColor Cyan }
function Write-Warning { Write-Host $args -ForegroundColor Yellow }
function Write-Step { Write-Host "  ➜ " -NoNewline -ForegroundColor Gray; Write-Host $args -ForegroundColor White }

Write-Host ""
Write-Host "═══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Switch JIT Environment: $Environment" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# Determine configuration based on environment
if ($Environment -eq "Local") {
    $targetUrl = "https://$NgrokDomain/api/JitAuthentication"
    $resourceId = "api://$NgrokDomain/$LocalAppId"
    $appObjectId = $LocalAppObjectId
    $appId = $LocalAppId
    $identifierUri = "api://$NgrokDomain/$LocalAppId"
} else {
    # Extract function app name from URL for Azure environment
    $functionHost = if ($AzureFunctionUrl -match "https://([^/]+)") { $matches[1] } else { "your-function-app" }

    $targetUrl = "$AzureFunctionUrl/api/JitAuthentication"
    $resourceId = "api://$functionHost/$AzureAppId"
    $appObjectId = $AzureAppObjectId
    $appId = $AzureAppId
    $identifierUri = "api://$functionHost/$AzureAppId"
}

Write-Info "Target Configuration:"
Write-Step "Environment:  $Environment"
Write-Step "Tenant ID:    $TenantId"
Write-Step "Target URL:   $targetUrl"
Write-Step "Resource ID:  $resourceId"
Write-Host ""

# Connect to Microsoft Graph
Write-Info "Connecting to Microsoft Graph..."
try {
    Connect-MgGraph -TenantId $TenantId -Scopes "Application.ReadWrite.All","CustomAuthenticationExtension.ReadWrite.All" -ErrorAction Stop | Out-Null
    Write-Success "✓ Connected to Microsoft Graph"
}
catch {
    Write-Host "Failed to connect to Microsoft Graph: $_" -ForegroundColor Red
    Write-Host ""
    Write-Warning "Make sure you have the required permissions:"
    Write-Host "  • Application.ReadWrite.All" -ForegroundColor Gray
    Write-Host "  • CustomAuthenticationExtension.ReadWrite.All" -ForegroundColor Gray
    exit 1
}

Write-Host ""

# Step 1: Update App Registration identifierUri
Write-Info "Step 1/2: Updating App Registration identifierUri..."
Write-Step "App Object ID: $appObjectId"
Write-Step "New URI:       $identifierUri"

$appBody = @{
    identifierUris = @($identifierUri)
} | ConvertTo-Json -Depth 10

try {
    Invoke-MgGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/v1.0/applications/$appObjectId" -Body $appBody -ContentType "application/json"
    Write-Success "✓ App Registration updated"
}
catch {
    Write-Host "Failed to update App Registration: $_" -ForegroundColor Red
    Write-Host ""
    if ($_.Exception.Response) {
        $reader = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream())
        $responseBody = $reader.ReadToEnd()
        Write-Host "Response: $responseBody" -ForegroundColor Red
    }
    exit 1
}

Write-Host ""

# Step 2: Update Custom Authentication Extension
Write-Info "Step 2/2: Updating Custom Authentication Extension..."
Write-Step "Extension ID:  $ExtensionId"
Write-Step "Target URL:    $targetUrl"
Write-Step "Resource ID:   $resourceId"

$extensionBody = @{
    "@odata.type" = "#microsoft.graph.onPasswordSubmitCustomExtension"
    authenticationConfiguration = @{
        "@odata.type" = "#microsoft.graph.azureAdTokenAuthentication"
        resourceId = $resourceId
    }
    endpointConfiguration = @{
        "@odata.type" = "#microsoft.graph.httpRequestEndpoint"
        targetUrl = $targetUrl
    }
} | ConvertTo-Json -Depth 10

try {
    Invoke-MgGraphRequest -Method PATCH -Uri "https://graph.microsoft.com/beta/identity/customAuthenticationExtensions/$ExtensionId" -Body $extensionBody -ContentType "application/json"
    Write-Success "✓ Custom Extension updated"
}
catch {
    Write-Host "Failed to update Custom Extension: $_" -ForegroundColor Red
    Write-Host ""
    if ($_.Exception.Response) {
        $reader = [System.IO.StreamReader]::new($_.Exception.Response.GetResponseStream())
        $responseBody = $reader.ReadToEnd()
        Write-Host "Response: $responseBody" -ForegroundColor Red
    }
    exit 1
}

Write-Host ""

# Verify the changes
Write-Info "Verifying configuration..."
try {
    $verifyExtension = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/beta/identity/customAuthenticationExtensions/$ExtensionId"
    
    $currentUrl = $verifyExtension.endpointConfiguration.targetUrl
    $currentResourceId = $verifyExtension.authenticationConfiguration.resourceId
    
    if ($currentUrl -eq $targetUrl -and $currentResourceId -eq $resourceId) {
        Write-Host ""
        Write-Host "═══════════════════════════════════════════════" -ForegroundColor Green
        Write-Success "✓ Configuration Updated Successfully!"
        Write-Host "═══════════════════════════════════════════════" -ForegroundColor Green
        Write-Host ""
        Write-Success "JIT Authentication is now configured for: $Environment"
        Write-Host ""
        Write-Host "Current Configuration:" -ForegroundColor Cyan
        Write-Step "Target URL:   $currentUrl"
        Write-Step "Resource ID:  $currentResourceId"
        Write-Host ""
        
        if ($Environment -eq "Local") {
            Write-Info "Next steps for LOCAL testing:"
            Write-Host "  1. Start ngrok:    " -NoNewline -ForegroundColor Gray
            Write-Host ".\src\B2CMigrationKit.Function\start-local.ps1" -ForegroundColor Yellow
            Write-Host "  2. Test login with a user that has requiresMigration=true" -ForegroundColor Gray
            Write-Host "  3. Monitor requests: " -NoNewline -ForegroundColor Gray
            Write-Host "http://localhost:4040" -ForegroundColor Cyan
        } else {
            Write-Info "Next steps for AZURE testing:"
            Write-Host "  1. Verify Azure Function is running" -ForegroundColor Gray
            Write-Host "  2. Check Function logs in Azure Portal" -ForegroundColor Gray
            Write-Host "  3. Test login with a user that has requiresMigration=true" -ForegroundColor Gray
        }
        Write-Host ""
    }
    else {
        Write-Warning "⚠️  Configuration mismatch detected!"
        Write-Warning "   Expected URL: $targetUrl"
        Write-Warning "   Got URL:      $currentUrl"
        Write-Warning "   Expected Resource: $resourceId"
        Write-Warning "   Got Resource:      $currentResourceId"
    }
}
catch {
    Write-Host "Failed to verify configuration: $_" -ForegroundColor Red
}

Write-Host ""
