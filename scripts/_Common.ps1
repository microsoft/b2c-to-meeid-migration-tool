# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
#
# _Common.ps1 - Shared helpers for all local-run scripts.
# Dot-source this file at the top of each script:
#   . (Join-Path $PSScriptRoot "_Common.ps1")

# ─── Output helpers ───────────────────────────────────────────────────────────
function Write-Success { param([string]$Message) Write-Host $Message -ForegroundColor Green }
function Write-Info    { param([string]$Message) Write-Host $Message -ForegroundColor Cyan  }
function Write-Warn    { param([string]$Message) Write-Host $Message -ForegroundColor Yellow }
function Write-Err     { param([string]$Message) Write-Host $Message -ForegroundColor Red   }

# ─── Azurite (VS Code extension) ──────────────────────────────────────────────
# Azurite is expected to be running via the
# "Azurite" VS Code extension (ms-azuretools.vscode-azurite).
# The scripts do NOT install or start Azurite automatically; instead they
# check whether the expected ports are already listening and guide the user
# to start the extension if they are not.

$AZURITE_BLOB_PORT  = 10000
$AZURITE_QUEUE_PORT = 10001

function Test-PortOpen {
    param([int]$Port)
    # Use a raw TcpClient instead of Test-NetConnection to avoid the
    # "Attempting TCP connect" progress message and IPv6 resolution delays.
    try {
        $tcp = [System.Net.Sockets.TcpClient]::new()
        $task = $tcp.ConnectAsync('127.0.0.1', $Port)
        $completed = $task.Wait(1000)   # 1 second timeout
        $connected = $completed -and $tcp.Connected
        $tcp.Close()
        return $connected
    }
    catch {
        return $false
    }
}

<#
.SYNOPSIS
    Verifies that Azurite is running (blob + queue ports open).
    If not, shows clear instructions to start it from VS Code and exits the caller.
.PARAMETER SkipAzurite
    When $true the check is skipped entirely (non-local storage detected).
#>
function Confirm-AzuriteRunning {
    param([bool]$SkipAzurite = $false)

    if ($SkipAzurite) {
        Write-Info "Skipping Azurite check (cloud storage configuration detected)."
        return
    }

    Write-Info "Checking Azurite (VS Code extension)..."

    $blobOk  = Test-PortOpen -Port $AZURITE_BLOB_PORT
    $queueOk = Test-PortOpen -Port $AZURITE_QUEUE_PORT

    if ($blobOk -and $queueOk) {
        Write-Success "✓ Azurite is running (blob :$AZURITE_BLOB_PORT / queue :$AZURITE_QUEUE_PORT)"
        return
    }

    Write-Err ""
    Write-Err "✗ Azurite is not running!"
    Write-Err ""
    Write-Info "Azurite is managed by the VS Code extension, not by npm."
    Write-Info "Start it from VS Code before running this script:"
    Write-Info ""
    Write-Info "  Option 1 – Command Palette  (Ctrl+Shift+P)  →  'Azurite: Start Service'"
    Write-Info "  Option 2 – Status bar       →  click  'Azurite Blob Service' / 'Azurite Queue Service'"
    Write-Info ""
    Write-Info "Extension page: https://marketplace.visualstudio.com/items?itemName=ms-azuretools.vscode-azurite"
    Write-Info ""

    if (-not $blobOk)  { Write-Warn "  Port $AZURITE_BLOB_PORT  (Blob)  – NOT listening" }
    if (-not $queueOk) { Write-Warn "  Port $AZURITE_QUEUE_PORT (Queue) – NOT listening" }

    Write-Err ""
    Write-Err "Start Azurite in VS Code and then re-run this script."
    exit 1
}

<#
.SYNOPSIS
    Reads the ConnectionStringOrUri from a config JSON file and decides
    whether local Azurite is required. Returns a hashtable with:
      NeedsAzurite : [bool]
      ConnString   : [string]
#>
function Get-StorageMode {
    param([string]$ConfigPath)

    try {
        $cfg = Get-Content $ConfigPath -Raw | ConvertFrom-Json
        $cs  = $cfg.Migration.Storage.ConnectionStringOrUri

        $isLocal = ($cs -eq "UseDevelopmentStorage=true") -or
                   ($cs -like "*127.0.0.1*") -or
                   ($cs -like "*localhost*")

        if ($isLocal) {
            Write-Info "Detected local storage (Azurite)."
        }
        else {
            Write-Info "Detected cloud storage – Azurite not required."
        }

        return @{ NeedsAzurite = $isLocal; ConnString = $cs }
    }
    catch {
        Write-Warn "⚠ Could not parse config for storage type – assuming Azurite."
        return @{ NeedsAzurite = $true; ConnString = "UseDevelopmentStorage=true" }
    }
}

<#
.SYNOPSIS
    Creates the required Azure Storage containers and queues for local development.
    Uses Azure CLI when available; otherwise emits a warning (resources are created
    automatically on first use).
.PARAMETER HarvestQueueName
    Name of the harvest queue (default: user-ids-to-process).
.PARAMETER PhoneRegQueueName
    Name of the phone-registration queue (default: phone-registration).
    Pass $null or empty string to skip creating this queue.
#>
function Initialize-LocalStorage {
    param(
        [string]$HarvestQueueName  = "user-ids-to-process",
        [string]$PhoneRegQueueName = "phone-registration"
    )

    Write-Info "Initializing local storage resources..."

    $azCli = Get-Command az -ErrorAction SilentlyContinue
    if (-not $azCli) {
        Write-Warn "⚠ Azure CLI (az) not found – skipping resource pre-creation."
        Write-Warn "  Resources will be created automatically on first use by the application."
        return
    }

    $cs = "UseDevelopmentStorage=true"
    $errors = 0

    # Harvest queue (producer → worker-migrate)
    $out = az storage queue create --name $HarvestQueueName --connection-string $cs --only-show-errors 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "  ⚠ Could not create queue '$HarvestQueueName' (may already exist)"
        $errors++
    }

    # Phone-registration queue (worker-migrate → phone-registration workers)
    if ($PhoneRegQueueName) {
        $out = az storage queue create --name $PhoneRegQueueName --connection-string $cs --only-show-errors 2>&1
        if ($LASTEXITCODE -ne 0) {
            Write-Warn "  ⚠ Could not create queue '$PhoneRegQueueName' (may already exist)"
            $errors++
        }
    }

    # Audit table
    $out = az storage table create --name "migrationAudit" --connection-string $cs --only-show-errors 2>&1
    if ($LASTEXITCODE -ne 0) {
        Write-Warn "  ⚠ Could not create table 'migrationAudit' (may already exist)"
        # not counted as blocking error
    }

    if ($errors -eq 0) {
        Write-Success "✓ Storage resources ready (queues + audit table)"
    }
    else {
        Write-Warn "  Some resources could not be pre-created – the app will create them on first use."
    }
}

<#
.SYNOPSIS
    Builds and runs the B2C Migration Kit console application.
.PARAMETER AppDir
    Directory containing the .csproj (must be the working directory for dotnet run).
.PARAMETER Operation
    The operation to pass as the first argument (harvest, worker-migrate, phone-registration).
.PARAMETER ConfigFile
    Config file name (relative to AppDir).
.PARAMETER VerboseLogging
    Adds --verbose flag.
#>
function Invoke-ConsoleApp {
    param(
        [string]$AppDir,
        [string]$Operation,
        [string]$ConfigFile,
        [bool]$VerboseLogging = $false
    )

    $appArgs = @($Operation, "--config", $ConfigFile)
    if ($VerboseLogging) { $appArgs += "--verbose" }

    try {
        Push-Location $AppDir

        Write-Info "Building console application..."
        dotnet build --configuration Debug --nologo --verbosity quiet | Out-Host

        if ($LASTEXITCODE -ne 0) {
            Write-Err "Build failed."
            exit 1
        }

        Write-Success "✓ Build successful"
        Write-Host ""

        dotnet run --no-build --configuration Debug -- $appArgs | Out-Host
        return $LASTEXITCODE
    }
    finally {
        Pop-Location
    }
}

# ─── Well-known Graph resource IDs ─────────────────────────────────────────────
# Source: https://learn.microsoft.com/en-us/graph/permissions-reference

# Microsoft Graph resource app ID (same in every tenant)
$GRAPH_APP_ID          = "00000003-0000-0000-c000-000000000000"

# Application permission role IDs (stable Microsoft-assigned GUIDs)
$PERM_USER_READ_ALL    = "df021288-bdef-4463-88db-98f22de89214"  # User.Read.All (Application)
$PERM_USER_READWRITE   = "741f803b-c850-494e-b5df-cde7c675a1ca"  # User.ReadWrite.All (Application)
$PERM_USER_AUTH_RW     = "50483e42-d915-4231-9639-7fdb7fd190e5"  # UserAuthenticationMethod.ReadWrite.All (Application)

# Public client used for device code authentication (Microsoft Graph Command Line Tools)
$DEVICE_CODE_CLIENT    = "14d82eec-204b-4c2f-b7e8-296a70dab67e"

# ─── Section header helper ─────────────────────────────────────────────────────

function Write-SectionHeader {
    param([string]$Title, [ConsoleColor]$Color = [ConsoleColor]::Cyan)
    $width = 62
    $line  = "═" * $width
    Write-Host ""
    Write-Host $line -ForegroundColor $Color
    Write-Host "  $Title" -ForegroundColor $Color
    Write-Host $line -ForegroundColor $Color
    Write-Host ""
}

function Write-SubHeader {
    param([string]$Title, [ConsoleColor]$Color = [ConsoleColor]::Yellow)
    $width = 62
    $line  = "─" * $width
    Write-Host ""
    Write-Host $line -ForegroundColor $Color
    Write-Host "  $Title" -ForegroundColor $Color
    Write-Host $line -ForegroundColor $Color
    Write-Host ""
}

# ─── Device code authentication helper ────────────────────────────────────────

function Get-DeviceCodeToken {
    param(
        [string]$TenantId,
        [string]$TenantLabel,
        [string[]]$Scopes
    )

    Write-SubHeader "Sign in as ADMIN in: $TenantLabel"
    Write-Info "Required permission: Application.ReadWrite.All"
    Write-Host ""

    try {
        $dcResp = Invoke-RestMethod -Method POST `
            -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/devicecode" `
            -Body @{
                client_id = $DEVICE_CODE_CLIENT
                scope     = ($Scopes -join ' ')
            }
    }
    catch {
        Write-Err "Device code request for '$TenantLabel' failed: $_"
        throw
    }

    Write-Host $dcResp.message -ForegroundColor White
    Write-Host ""
    Write-Host "  Waiting for authentication..." -ForegroundColor Gray

    $deadline = [DateTime]::UtcNow.AddSeconds([int]$dcResp.expires_in)
    $interval = [int]$dcResp.interval

    while ([DateTime]::UtcNow -lt $deadline) {
        Start-Sleep -Seconds $interval
        try {
            $tok = Invoke-RestMethod -Method POST `
                -Uri "https://login.microsoftonline.com/$TenantId/oauth2/v2.0/token" `
                -Body @{
                    grant_type  = 'urn:ietf:params:oauth:grant-type:device_code'
                    client_id   = $DEVICE_CODE_CLIENT
                    device_code = $dcResp.device_code
                }
            Write-Success "✓ Authenticated to $TenantLabel"
            return $tok.access_token
        }
        catch {
            $body = $null
            if ($_.ErrorDetails.Message) {
                $body = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
            }
            switch ($body.error) {
                "authorization_pending" { continue }
                "authorization_declined" { throw "Authentication was declined." }
                "expired_token"          { throw "Device code expired — please re-run the script." }
                default                  { throw }
            }
        }
    }
    throw "Authentication timed out after $($dcResp.expires_in)s"
}

# ─── Graph REST helper ─────────────────────────────────────────────────────────

function Invoke-Graph {
    param(
        [string]$Method,
        [string]$Uri,
        [hashtable]$Headers,
        [object]$Body = $null
    )
    $params = @{
        Method      = $Method
        Uri         = $Uri
        Headers     = $Headers
        ContentType = "application/json"
    }
    if ($null -ne $Body) {
        $params.Body = ($Body | ConvertTo-Json -Depth 10)
    }
    try {
        return Invoke-RestMethod @params
    }
    catch {
        $detail = ""
        if ($_.ErrorDetails.Message) {
            $ej = $_.ErrorDetails.Message | ConvertFrom-Json -ErrorAction SilentlyContinue
            if ($ej.error) { $detail = " – [$($ej.error.code)] $($ej.error.message)" }
        }
        throw "Graph $Method $Uri failed$detail"
    }
}

# Locate the Microsoft Graph service principal object ID in a tenant
function Get-GraphSpId {
    param([hashtable]$Headers, [string]$TenantLabel)
    $res = Invoke-Graph -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=appId eq '$GRAPH_APP_ID'&`$select=id" `
        -Headers $Headers
    if (-not $res.value -or $res.value.Count -eq 0) {
        throw "Microsoft Graph service principal not found in $TenantLabel. Cannot grant admin consent."
    }
    return $res.value[0].id
}

# Create an app registration + SP, grant admin consent, and add a client secret.
# Returns @{ AppObjectId; ClientId; ClientSecret }
function New-WorkerApp {
    param(
        [hashtable]$Headers,
        [string]$AppDisplayName,
        [string[]]$PermissionRoleIds,
        [string]$GraphSpId,
        [string]$TenantLabel,
        [int]$WorkerNumber,
        [int]$SecretExpiryYears = 2
    )

    Write-Info "  [$TenantLabel] Provisioning '$AppDisplayName'..."

    # Check if app already exists by displayName (idempotent)
    $filter = "displayName eq '$AppDisplayName'"
    $existing = Invoke-Graph -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=$filter&`$select=id,appId" `
        -Headers $Headers

    if ($existing.value -and $existing.value.Count -gt 0) {
        $app = $existing.value[0]
        Write-Info "    App already exists — reusing (Object ID: $($app.id), Client ID: $($app.appId))"

        # Ensure service principal exists
        $spFilter = "appId eq '$($app.appId)'"
        $spResult = Invoke-Graph -Method GET `
            -Uri "https://graph.microsoft.com/v1.0/servicePrincipals?`$filter=$spFilter&`$select=id" `
            -Headers $Headers
        if (-not $spResult.value -or $spResult.value.Count -eq 0) {
            $sp = Invoke-Graph -Method POST `
                -Uri "https://graph.microsoft.com/v1.0/servicePrincipals" `
                -Headers $Headers `
                -Body @{ appId = $app.appId }
            Write-Info "    Created missing service principal: $($sp.id)"
        }
        else {
            $sp = $spResult.value[0]
        }

        # Ensure admin consent for all permissions (idempotent)
        foreach ($roleId in $PermissionRoleIds) {
            try {
                Invoke-Graph -Method POST `
                    -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($sp.id)/appRoleAssignments" `
                    -Headers $Headers `
                    -Body @{
                        principalId = $sp.id
                        resourceId  = $GraphSpId
                        appRoleId   = $roleId
                    } | Out-Null
                Write-Info "    Admin consent granted for role $roleId"
            }
            catch {
                if ($_.Exception.Message -match 'Permission being assigned already exists') {
                    Write-Info "    Admin consent already granted for role $roleId"
                }
                else { throw }
            }
        }

        # Create a new secret (always — old secrets still work)
        $expiry     = [DateTime]::UtcNow.AddYears($SecretExpiryYears).ToString("yyyy-MM-ddTHH:mm:ssZ")
        $secretResp = Invoke-Graph -Method POST `
            -Uri "https://graph.microsoft.com/v1.0/applications/$($app.id)/addPassword" `
            -Headers $Headers `
            -Body @{
                passwordCredential = @{
                    displayName = "worker-$WorkerNumber-local-dev"
                    endDateTime = $expiry
                }
            }
        Write-Success "    ✓ Reused existing app (new secret expires $expiry)"

        return @{
            AppObjectId  = $app.id
            ClientId     = $app.appId
            ClientSecret = $secretResp.secretText
        }
    }

    # App does not exist — create it
    $resourceAccess = $PermissionRoleIds | ForEach-Object { @{ id = $_; type = "Role" } }
    $app = Invoke-Graph -Method POST `
        -Uri "https://graph.microsoft.com/v1.0/applications" `
        -Headers $Headers `
        -Body @{
            displayName            = $AppDisplayName
            signInAudience         = "AzureADMyOrg"
            requiredResourceAccess = @(
                @{
                    resourceAppId  = $GRAPH_APP_ID
                    resourceAccess = @($resourceAccess)
                }
            )
        }
    Write-Info "    App object ID : $($app.id)"
    Write-Info "    Client ID     : $($app.appId)"

    # 2. Create service principal (required for admin consent grant)
    Start-Sleep -Seconds 3   # wait for app creation to propagate
    $sp = Invoke-Graph -Method POST `
        -Uri "https://graph.microsoft.com/v1.0/servicePrincipals" `
        -Headers $Headers `
        -Body @{ appId = $app.appId }
    Write-Info "    Service principal: $($sp.id)"

    # 3. Grant admin consent via app role assignments
    foreach ($roleId in $PermissionRoleIds) {
        Invoke-Graph -Method POST `
            -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($sp.id)/appRoleAssignments" `
            -Headers $Headers `
            -Body @{
                principalId = $sp.id
                resourceId  = $GraphSpId
                appRoleId   = $roleId
            } | Out-Null
        Write-Info "    Admin consent granted for role $roleId"
    }

    # 4. Create client secret
    $expiry     = [DateTime]::UtcNow.AddYears($SecretExpiryYears).ToString("yyyy-MM-ddTHH:mm:ssZ")
    $secretResp = Invoke-Graph -Method POST `
        -Uri "https://graph.microsoft.com/v1.0/applications/$($app.id)/addPassword" `
        -Headers $Headers `
        -Body @{
            passwordCredential = @{
                displayName = "worker-$WorkerNumber-local-dev"
                endDateTime = $expiry
            }
        }
    Write-Success "    ✓ Created new app (secret expires $expiry)"

    return @{
        AppObjectId  = $app.id
        ClientId     = $app.appId
        ClientSecret = $secretResp.secretText
    }
}

# Ensure required extension properties exist on the ExtensionApp in EEID tenant (idempotent)
function Ensure-ExtensionProperties {
    param(
        [hashtable]$Headers,
        [string]$ExtensionAppId   # without hyphens, e.g. "7343db9f2a60428caab75693cc9172e3"
    )

    # Convert no-hyphen appId to GUID format for Graph filter
    $appIdGuid = $ExtensionAppId.Insert(8, '-').Insert(13, '-').Insert(18, '-').Insert(23, '-')

    Write-Info "Ensuring extension properties on ExtensionApp ($appIdGuid)..."

    # Find the application object by appId
    $filter = "appId eq '$appIdGuid'"
    $result = Invoke-Graph -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/applications?`$filter=$filter&`$select=id,appId,displayName" `
        -Headers $Headers

    if (-not $result.value -or $result.value.Count -eq 0) {
        throw "Extension app with appId '$appIdGuid' not found in the EEID tenant. Verify ExtensionAppId in config."
    }

    $appObjectId = $result.value[0].id
    $appName     = $result.value[0].displayName
    Write-Info "  Found: '$appName' (Object ID: $appObjectId)"

    # List existing extension properties
    $existing = Invoke-Graph -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/applications/$appObjectId/extensionProperties?`$select=name,dataType,targetObjects" `
        -Headers $Headers

    $existingNames = @()
    if ($existing.value) {
        $existingNames = $existing.value | ForEach-Object { $_.name }
    }

    $requiredProps = @(
        @{ Name = "B2CObjectId";       DataType = "String";  FullName = "extension_${ExtensionAppId}_B2CObjectId" }
        @{ Name = "RequiresMigration"; DataType = "Boolean"; FullName = "extension_${ExtensionAppId}_RequiresMigration" }
    )

    $created = 0
    foreach ($prop in $requiredProps) {
        if ($existingNames -contains $prop.FullName) {
            Write-Success "  ✓ $($prop.FullName) — already exists"
        }
        else {
            Write-Info "  Creating $($prop.Name) ($($prop.DataType))..."
            Invoke-Graph -Method POST `
                -Uri "https://graph.microsoft.com/v1.0/applications/$appObjectId/extensionProperties" `
                -Headers $Headers `
                -Body @{
                    name          = $prop.Name
                    dataType      = $prop.DataType
                    targetObjects = @("User")
                } | Out-Null
            Write-Success "  ✓ $($prop.FullName) — created"
            $created++
        }
    }

    if ($created -eq 0) {
        Write-Success "All extension properties already exist."
    }
    else {
        Write-Success "$created extension property/ies created."
    }
}

# ─── Azure deployment config generators ────────────────────────────────────────
# These generate role-specific appsettings for Azure VMs (managed identity storage).

function New-MasterConfigContent {
    param(
        [string]$B2cTenantId,
        [string]$B2cTenantDomain,
        [string]$B2cClientId,
        [string]$B2cClientSecret,
        [string]$StorageAccountName
    )
    $storageUri = "https://${StorageAccountName}.blob.core.windows.net"
    return @"
{
  "Logging": {
    "LogLevel": {
      "Default": "Information",
      "Microsoft": "Warning"
    }
  },
  "Migration": {
    "B2C": {
      "TenantId": "$B2cTenantId",
      "TenantDomain": "$B2cTenantDomain",
      "AppRegistration": {
        "ClientId": "$B2cClientId",
        "ClientSecret": "$B2cClientSecret",
        "Name": "B2C App Registration (Master)",
        "Enabled": true
      },
      "Scopes": ["https://graph.microsoft.com/.default"]
    },
    "ExternalId": {
      "TenantId": "",
      "TenantDomain": "",
      "ExtensionAppId": "",
      "AppRegistration": {
        "ClientId": "",
        "ClientSecret": "",
        "Name": "Not used by harvest",
        "Enabled": false
      },
      "Scopes": ["https://graph.microsoft.com/.default"]
    },
    "Storage": {
      "ConnectionStringOrUri": "$storageUri",
      "ExportContainerName": "user-exports",
      "ErrorContainerName": "migration-errors",
      "ImportAuditContainerName": "import-audit",
      "ExportBlobPrefix": "users_",
      "AuditTableName": "migrationAudit",
      "AuditMode": "File",
      "AuditFilePath": "migration-audit-master.jsonl",
      "UseManagedIdentity": true
    },
    "Telemetry": {
      "ConnectionString": "",
      "Enabled": true,
      "UseApplicationInsights": false,
      "UseConsoleLogging": true,
      "SamplingPercentage": 100.0,
      "TrackDependencies": true,
      "TrackExceptions": true,
      "LogFilePath": "master-telemetry.jsonl"
    },
    "Retry": {
      "MaxRetries": 5,
      "InitialDelayMs": 1000,
      "MaxDelayMs": 30000,
      "BackoffMultiplier": 2.0,
      "UseRetryAfterHeader": true,
      "OperationTimeoutSeconds": 120
    },
    "Export": {
      "SelectFields": "id,userPrincipalName,displayName,givenName,surname,mail,mobilePhone,identities"
    },
    "Harvest": {
      "QueueName": "user-ids-to-process",
      "IdsPerMessage": 20,
      "PageSize": 999,
      "MessageVisibilityTimeout": "00:05:00",
      "MaxUsers": 0
    },
    "BatchDelayMs": 0,
    "MaxConcurrency": 8
  }
}
"@
}

function New-UserWorkerConfigContent {
    param(
        [int]   $WorkerN,
        [string]$B2cTenantId,
        [string]$B2cTenantDomain,
        [string]$B2cClientId,
        [string]$B2cClientSecret,
        [string]$EeidTenantId,
        [string]$EeidTenantDomain,
        [string]$ExtAppId,
        [string]$EeidClientId,
        [string]$EeidClientSecret,
        [string]$StorageAccountName,
        [string]$UpnSuffix = ""
    )
    $storageUri = "https://${StorageAccountName}.blob.core.windows.net"
    $upnSuffixJson = if ($UpnSuffix) { ",`n      `"UpnSuffix`": `"$UpnSuffix`"" } else { "" }
    return @"
{
  "Logging": {
    "LogLevel": {
      "Default": "Information",
      "Microsoft": "Warning"
    }
  },
  "Migration": {
    "B2C": {
      "TenantId": "$B2cTenantId",
      "TenantDomain": "$B2cTenantDomain",
      "AppRegistration": {
        "ClientId": "$B2cClientId",
        "ClientSecret": "$B2cClientSecret",
        "Name": "B2C App Registration (User Worker $WorkerN)",
        "Enabled": true
      },
      "Scopes": ["https://graph.microsoft.com/.default"]
    },
    "ExternalId": {
      "TenantId": "$EeidTenantId",
      "TenantDomain": "$EeidTenantDomain",
      "ExtensionAppId": "$ExtAppId",
      "AppRegistration": {
        "ClientId": "$EeidClientId",
        "ClientSecret": "$EeidClientSecret",
        "Name": "EEID App Registration (User Worker $WorkerN)",
        "Enabled": true
      },
      "Scopes": ["https://graph.microsoft.com/.default"]
    },
    "Storage": {
      "ConnectionStringOrUri": "$storageUri",
      "ExportContainerName": "user-exports",
      "ErrorContainerName": "migration-errors",
      "ImportAuditContainerName": "import-audit",
      "ExportBlobPrefix": "users_",
      "AuditTableName": "migrationAudit",
      "AuditMode": "File",
      "AuditFilePath": "migration-audit-user-worker${WorkerN}.jsonl",
      "UseManagedIdentity": true
    },
    "Telemetry": {
      "ConnectionString": "",
      "Enabled": true,
      "UseApplicationInsights": false,
      "UseConsoleLogging": true,
      "SamplingPercentage": 100.0,
      "TrackDependencies": true,
      "TrackExceptions": true,
      "LogFilePath": "user-worker${WorkerN}-telemetry.jsonl"
    },
    "Retry": {
      "MaxRetries": 5,
      "InitialDelayMs": 1000,
      "MaxDelayMs": 30000,
      "BackoffMultiplier": 2.0,
      "UseRetryAfterHeader": true,
      "OperationTimeoutSeconds": 120
    },
    "Export": {
      "SelectFields": "id,userPrincipalName,displayName,givenName,surname,mail,mobilePhone,identities"
    },
    "Harvest": {
      "QueueName": "user-ids-to-process",
      "IdsPerMessage": 20,
      "PageSize": 999,
      "MessageVisibilityTimeout": "00:05:00",
      "MaxUsers": 0
    },
    "Import": {
      "AttributeMappings": {},
      "ExcludeFields": ["createdDateTime", "lastPasswordChangeDateTime"],
      "MigrationAttributes": {
        "StoreB2CObjectId": true,
        "SetRequireMigration": true,
        "OverwriteExtensionAttributes": false
      },
      "SkipPhoneRegistration": false$upnSuffixJson
    },
    "PhoneRegistration": {
      "QueueName": "phone-registration",
      "ThrottleDelayMs": 400,
      "MessageVisibilityTimeoutSeconds": 120,
      "EmptyQueuePollDelayMs": 5000,
      "MaxEmptyPolls": 3,
      "UseFakePhoneWhenMissing": false
    },
    "BatchDelayMs": 0,
    "MaxConcurrency": 8
  }
}
"@
}

function New-PhoneWorkerConfigContent {
    param(
        [int]   $WorkerN,
        [string]$B2cTenantId,
        [string]$B2cTenantDomain,
        [string]$B2cClientId,
        [string]$B2cClientSecret,
        [string]$EeidTenantId,
        [string]$EeidTenantDomain,
        [string]$ExtAppId,
        [string]$EeidClientId,
        [string]$EeidClientSecret,
        [string]$StorageAccountName
    )
    $storageUri = "https://${StorageAccountName}.blob.core.windows.net"
    return @"
{
  "Logging": {
    "LogLevel": {
      "Default": "Information",
      "Microsoft": "Warning"
    }
  },
  "Migration": {
    "B2C": {
      "TenantId": "$B2cTenantId",
      "TenantDomain": "$B2cTenantDomain",
      "AppRegistration": {
        "ClientId": "$B2cClientId",
        "ClientSecret": "$B2cClientSecret",
        "Name": "B2C App Registration (Phone Worker $WorkerN)",
        "Enabled": true
      },
      "Scopes": ["https://graph.microsoft.com/.default"]
    },
    "ExternalId": {
      "TenantId": "$EeidTenantId",
      "TenantDomain": "$EeidTenantDomain",
      "ExtensionAppId": "$ExtAppId",
      "AppRegistration": {
        "ClientId": "$EeidClientId",
        "ClientSecret": "$EeidClientSecret",
        "Name": "EEID App Registration (Phone Worker $WorkerN)",
        "Enabled": true
      },
      "Scopes": ["https://graph.microsoft.com/.default"]
    },
    "Storage": {
      "ConnectionStringOrUri": "$storageUri",
      "AuditTableName": "migrationAudit",
      "AuditMode": "File",
      "AuditFilePath": "migration-audit-phone-worker${WorkerN}.jsonl",
      "UseManagedIdentity": true
    },
    "Telemetry": {
      "ConnectionString": "",
      "Enabled": true,
      "UseApplicationInsights": false,
      "UseConsoleLogging": true,
      "SamplingPercentage": 100.0,
      "TrackDependencies": true,
      "TrackExceptions": true,
      "LogFilePath": "phone-worker${WorkerN}-telemetry.jsonl"
    },
    "Retry": {
      "MaxRetries": 5,
      "InitialDelayMs": 1000,
      "MaxDelayMs": 30000,
      "BackoffMultiplier": 2.0,
      "UseRetryAfterHeader": true,
      "OperationTimeoutSeconds": 120
    },
    "PhoneRegistration": {
      "QueueName": "phone-registration",
      "ThrottleDelayMs": 400,
      "MessageVisibilityTimeoutSeconds": 120,
      "EmptyQueuePollDelayMs": 5000,
      "MaxEmptyPolls": 3,
      "UseFakePhoneWhenMissing": false
    },
    "BatchDelayMs": 0,
    "MaxConcurrency": 8
  }
}
"@
}

# Build the JSON content for appsettings.workerN.json (local dev mode)
function New-WorkerAppSettingsContent {
    param(
        [int]   $WorkerN,
        [string]$B2cTenantId,
        [string]$B2cTenantDomain,
        [string]$B2cClientId,
        [string]$B2cClientSecret,
        [string]$EeidTenantId,
        [string]$EeidTenantDomain,
        [string]$ExtAppId,
        [string]$EeidClientId,
        [string]$EeidClientSecret,
        [string]$StorageConnectionString = "UseDevelopmentStorage=true"
    )

    return @"
{
  "Logging": {
    "LogLevel": {
      "Default": "Information",
      "Microsoft": "Warning"
    }
  },
  "Migration": {
    "B2C": {
      "TenantId": "$B2cTenantId",
      "TenantDomain": "$B2cTenantDomain",
      "AppRegistration": {
        "ClientId": "$B2cClientId",
        "ClientSecret": "$B2cClientSecret",
        "Name": "B2C App Registration (Local - Worker $WorkerN)",
        "Enabled": true
      },
      "Scopes": [
        "https://graph.microsoft.com/.default"
      ]
    },
    "ExternalId": {
      "TenantId": "$EeidTenantId",
      "TenantDomain": "$EeidTenantDomain",
      "ExtensionAppId": "$ExtAppId",
      "AppRegistration": {
        "ClientId": "$EeidClientId",
        "ClientSecret": "$EeidClientSecret",
        "Name": "External ID App Registration $WorkerN (Local)",
        "Enabled": true
      },
      "Scopes": [
        "https://graph.microsoft.com/.default"
      ]
    },
    "Storage": {
      "ConnectionStringOrUri": "$StorageConnectionString",
      "AuditTableName": "migrationAudit",
      "AuditMode": "File",
      "AuditFilePath": "migration-audit-worker${WorkerN}.jsonl",
      "UseManagedIdentity": false
    },
    "Telemetry": {
      "ConnectionString": "",
      "Enabled": true,
      "UseApplicationInsights": false,
      "UseConsoleLogging": true,
      "SamplingPercentage": 100.0,
      "TrackDependencies": true,
      "TrackExceptions": true,
      "LogFilePath": "worker${WorkerN}-telemetry.jsonl"
    },
    "Retry": {
      "MaxRetries": 5,
      "InitialDelayMs": 1000,
      "MaxDelayMs": 30000,
      "BackoffMultiplier": 2.0,
      "UseRetryAfterHeader": true,
      "OperationTimeoutSeconds": 120
    },
    "Export": {
      "SelectFields": "id,userPrincipalName,displayName,givenName,surname,mail,mobilePhone,identities",
      "WorkerBlobPrefix": "w${WorkerN}_"
    },
    "Import": {
      "AttributeMappings": {},
      "ExcludeFields": [
        "createdDateTime",
        "lastPasswordChangeDateTime"
      ],
      "MigrationAttributes": {
        "StoreB2CObjectId": true,
        "SetRequireMigration": true,
        "OverwriteExtensionAttributes": false
      },
      "SkipPhoneRegistration": false
    },
    "BatchSize": 100,
    "PageSize": 100,
    "VerboseLogging": true,
    "BatchDelayMs": 0,
    "MaxConcurrency": 8
  }
}
"@
}
