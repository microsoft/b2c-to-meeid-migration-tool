# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
<#
.SYNOPSIS
    Queries and manages the RequiresMigration flag for users in Entra External ID.

.DESCRIPTION
    This script allows administrators to:
      1. List users filtered by their RequiresMigration flag value.
      2. Update (set/clear) the RequiresMigration flag for a specific user or for all
         users that match a given filter.

    Authentication uses client credentials (ClientId + ClientSecret) from the target
    ExternalId app registration in the supplied configuration file.

    The extension attribute name is derived from:
      - Migration.ExternalId.ExtensionAppId  (from config)
      - Migration.Import.MigrationAttributes.RequireMigrationTarget  (optional override)
      → default: extension_{ExtensionAppId}_RequiresMigration

.PARAMETER ConfigFile
    Path to the appsettings JSON file (relative to the console project directory).
    Default: appsettings.worker1.json

.PARAMETER Filter
    Which users to list/update based on the current flag value.
    Accepted values:
      true    – users whose flag is set to true  (pending JIT migration)
      false   – users whose flag is set to false (already migrated)
      notset  – users that do not have the attribute at all
      all     – all users (no filter on the flag)
    Default: true

.PARAMETER SetFlag
    When supplied, updates the RequiresMigration attribute for every user returned
    by the query (respecting -Filter and -UserId).
    Accepted values: true | false

.PARAMETER UserId
    Target a single user by their Entra External ID object ID.
    If specified together with -SetFlag, only that user is updated.
    Ignores -Filter and -MaxUsers.

.PARAMETER UserUpn
    Target a single user by their User Principal Name (UPN).
    Resolves to Object ID automatically.
    Example: testjitusse_slider-inc.com#EXT#@lagomarciamdemo2.onmicrosoft.com

.PARAMETER AttributeName
    Override the extension attribute name used for the migration flag.
    Use -Discover to list available extension properties and find the exact name.
    Example: extension_abc123_RequiresMigration

.PARAMETER MaxUsers
    Maximum number of users to retrieve / update.
    Has no effect when -UserId is specified.
    Default: 100

.PARAMETER Discover
    Lists all extension properties registered in the tenant for the Extension App.
    Use this to find the exact attribute name when the default one is incorrect.

.PARAMETER WhatIf
    Preview the changes that would be made without actually updating any user.

.EXAMPLE
    # List users that still need JIT migration (flag = true)
    .\Manage-MigrationFlag.ps1

.EXAMPLE
    # List users already fully migrated (flag = false)
    .\Manage-MigrationFlag.ps1 -Filter false

.EXAMPLE
    # List all users regardless of flag value
    .\Manage-MigrationFlag.ps1 -Filter all

.EXAMPLE
    # Clear the migration flag for all users where it is still true (preview)
    .\Manage-MigrationFlag.ps1 -Filter true -SetFlag false -WhatIf

.EXAMPLE
    # Clear the migration flag for all users where it is still true
    .\Manage-MigrationFlag.ps1 -Filter true -SetFlag false

.EXAMPLE
    # Set the migration flag to true for a specific user by Object ID
    .\Manage-MigrationFlag.ps1 -UserId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -SetFlag true

.EXAMPLE
    # Set the migration flag to true for a specific user by UPN
    .\Manage-MigrationFlag.ps1 -UserUpn "user_domain.com#EXT#@tenant.onmicrosoft.com" -SetFlag true

.EXAMPLE
    # Discover the exact extension attribute name registered in the tenant
    .\Manage-MigrationFlag.ps1 -Discover

.EXAMPLE
    # Use a known attribute name directly (bypasses auto-derivation)
    .\Manage-MigrationFlag.ps1 -Filter false -AttributeName "extension_abc123_RequiresMigration"

.EXAMPLE
    # Use a custom configuration file
    .\Manage-MigrationFlag.ps1 -ConfigFile "appsettings.worker2.json" -Filter false

.PARAMETER DeleteByPrefix
    Deletes ALL External ID users whose UPN starts with the given prefix.
    Intended for test environment cleanup (e.g. remove all "bulkuser" test accounts).
    Supports -WhatIf (preview), -CountOnly (count without deleting), and -MaxUsers (safety cap, default 100).
    WARNING: Irreversible. Always run with -WhatIf or -CountOnly first.

.PARAMETER CountOnly
    When used with -DeleteByPrefix, queries the total number of matching users and exits without
    modifying or listing them. Uses the OData $count annotation — returns the real total instantly,
    regardless of -MaxUsers.

.EXAMPLE
    # Count how many bulkuser accounts exist (no changes)
    .\.Manage-MigrationFlag.ps1 -DeleteByPrefix "bulkuser" -CountOnly

.EXAMPLE
    # Preview which accounts would be deleted (no changes applied)
    .\Manage-MigrationFlag.ps1 -DeleteByPrefix "bulkuser" -WhatIf

.EXAMPLE
    # Delete all bulkuser accounts in External ID (up to 10 000)
    .\Manage-MigrationFlag.ps1 -DeleteByPrefix "bulkuser" -MaxUsers 10000
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigFile = "appsettings.worker1.json",

    [Parameter(Mandatory = $false)]
    [ValidateSet("true", "false", "notset", "all")]
    [string]$Filter = "true",

    [Parameter(Mandatory = $false)]
    [ValidateSet("true", "false")]
    [string]$SetFlag,

    [Parameter(Mandatory = $false)]
    [string]$UserId,

    [Parameter(Mandatory = $false)]
    [string]$UserUpn,

    [Parameter(Mandatory = $false)]
    [string]$AttributeName,

    [Parameter(Mandatory = $false)]
    [int]$MaxUsers = 100,

    [Parameter(Mandatory = $false)]
    [switch]$Discover,

    [Parameter(Mandatory = $false)]
    [switch]$WhatIf,

    [Parameter(Mandatory = $false)]
    [switch]$CountOnly,

    [Parameter(Mandatory = $false)]
    [string]$DeleteByPrefix
)

$ErrorActionPreference = "Stop"

# Shared helpers
. (Join-Path $PSScriptRoot "_Common.ps1")

# ─── Resolve config file path ────────────────────────────────────────────────
$rootDir       = Split-Path -Parent $PSScriptRoot
$consoleAppDir = Join-Path $rootDir "src\B2CMigrationKit.Console"
$configPath    = $ConfigFile

if (-not [System.IO.Path]::IsPathRooted($ConfigFile)) {
    $configPath = Join-Path $consoleAppDir $ConfigFile
}

if (-not (Test-Path $configPath)) {
    Write-Err "Configuration file not found: $configPath"
    Write-Info "Use -ConfigFile to specify a different path."
    exit 1
}

# ─── Header ──────────────────────────────────────────────────────────────────
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  B2C Migration Kit - Migration Flag Manager"           -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# ─── Load configuration ───────────────────────────────────────────────────────
Write-Info "Loading configuration: $ConfigFile"

try {
    $cfg = Get-Content $configPath -Raw | ConvertFrom-Json
}
catch {
    Write-Err "Failed to parse configuration file: $_"
    exit 1
}

$tenantId     = $cfg.Migration.ExternalId.TenantId
$clientId     = $cfg.Migration.ExternalId.AppRegistration.ClientId
$clientSecret = $cfg.Migration.ExternalId.AppRegistration.ClientSecret
$extensionAppId = $cfg.Migration.ExternalId.ExtensionAppId

# Validate required fields
$missing = @()
if ([string]::IsNullOrWhiteSpace($tenantId))       { $missing += "Migration.ExternalId.TenantId" }
if ([string]::IsNullOrWhiteSpace($clientId))        { $missing += "Migration.ExternalId.AppRegistration.ClientId" }
if ([string]::IsNullOrWhiteSpace($clientSecret))    { $missing += "Migration.ExternalId.AppRegistration.ClientSecret" }
if ([string]::IsNullOrWhiteSpace($extensionAppId))  { $missing += "Migration.ExternalId.ExtensionAppId" }

if ($missing.Count -gt 0) {
    Write-Err "Missing required configuration fields:"
    $missing | ForEach-Object { Write-Err "  - $_" }
    exit 1
}

# Determine the extension attribute name (priority: -AttributeName > config > default)
if (-not [string]::IsNullOrWhiteSpace($AttributeName)) {
    $requireMigrationAttr = $AttributeName
}
else {
    $requireMigrationAttr = $cfg.Migration.Import.MigrationAttributes.RequireMigrationTarget
    if ([string]::IsNullOrWhiteSpace($requireMigrationAttr)) {
        $cleanAppId = $extensionAppId -replace "-", ""
        $requireMigrationAttr = "extension_${cleanAppId}_RequireMigration"
    }
}

Write-Success "✓ Configuration loaded"
Write-Info   "  Tenant          : $tenantId"
Write-Info   "  Extension AppId : $extensionAppId"
Write-Info   "  Migration attr  : $requireMigrationAttr"
Write-Host ""

# ─── Acquire access token ─────────────────────────────────────────────────────
Write-Info "Acquiring access token (client credentials)..."

try {
    $tokenUri  = "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token"
    $tokenBody = @{
        grant_type    = "client_credentials"
        client_id     = $clientId
        client_secret = $clientSecret
        scope         = "https://graph.microsoft.com/.default"
    }

    $tokenResponse = Invoke-RestMethod -Method Post -Uri $tokenUri -Body $tokenBody -ContentType "application/x-www-form-urlencoded"
    $accessToken   = $tokenResponse.access_token
}
catch {
    Write-Err "Failed to acquire access token: $_"
    exit 1
}

Write-Success "✓ Access token acquired"
Write-Host ""

$headers = @{
    Authorization  = "Bearer $accessToken"
    "Content-Type" = "application/json"
}

# ─── Mode: discover extension properties ─────────────────────────────────────
if ($Discover) {
    Write-Info "Looking up extension app object ID for AppId: $extensionAppId ..."

    try {
        $cleanAppId  = $extensionAppId -replace "-", ""
        $appsUri     = "https://graph.microsoft.com/v1.0/applications?`$filter=appId eq '$extensionAppId'&`$select=id,displayName,appId"
        $appsResult  = Invoke-RestMethod -Method Get -Uri $appsUri -Headers $headers

        if ($appsResult.value.Count -eq 0) {
            Write-Warn "No application found with AppId '$extensionAppId'."
            Write-Info "Make sure ExtensionAppId in config matches the App Registration used to define custom attributes."
            exit 1
        }

        $appObjectId = $appsResult.value[0].id
        $appName     = $appsResult.value[0].displayName
        Write-Success "✓ Found app: '$appName' (Object ID: $appObjectId)"
        Write-Host ""

        $extUri    = "https://graph.microsoft.com/v1.0/applications/$appObjectId/extensionProperties"
        $extResult = Invoke-RestMethod -Method Get -Uri $extUri -Headers $headers

        if ($extResult.value.Count -eq 0) {
            Write-Warn "No extension properties registered for this app."
            exit 0
        }

        Write-Success "Extension properties registered ($($extResult.value.Count) total):"
        Write-Host ""

        $extResult.value | ForEach-Object {
            $isMigFlag = $_.name -match "RequiresMigration"
            $color     = if ($isMigFlag) { "Yellow" } else { "Gray" }
            Write-Host ("  {0,-70}  [{1}]" -f $_.name, $_.dataType) -ForegroundColor $color
        }

        Write-Host ""
        Write-Info "To use a specific attribute name, run:"
        Write-Info "  .\Manage-MigrationFlag.ps1 -Filter false -AttributeName `"extension_..._RequiresMigration`""
    }
    catch {
        Write-Err "Failed to retrieve extension properties: $_"
        exit 1
    }

    exit 0
}

# ─── Helper: call Graph with paging ──────────────────────────────────────────
function Invoke-GraphGet {
    param([string]$Uri)
    try {
        return Invoke-RestMethod -Method Get -Uri $Uri -Headers $headers
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        Write-Err "Graph GET failed ($statusCode): $_"
        throw
    }
}

function Invoke-GraphPatch {
    param([string]$Uri, [string]$Body)
    try {
        Invoke-RestMethod -Method Patch -Uri $Uri -Headers $headers -Body $Body | Out-Null
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        Write-Err "Graph PATCH failed ($statusCode): $_"
        throw
    }
}

function Invoke-GraphDelete {
    param([string]$Uri)
    try {
        Invoke-RestMethod -Method Delete -Uri $Uri -Headers $headers | Out-Null
    }
    catch {
        $statusCode = $_.Exception.Response.StatusCode.value__
        Write-Err "Graph DELETE failed ($statusCode): $_"
        throw
    }
}

# ─── Build Graph query ────────────────────────────────────────────────────────
$selectFields = "id,userPrincipalName,displayName,mail,$requireMigrationAttr"
$graphBase    = "https://graph.microsoft.com/v1.0"

function Get-Users {
    param([string]$ODataFilter, [int]$Max)

    $users      = [System.Collections.Generic.List[object]]::new()
    $encodedSel = [uri]::EscapeDataString($selectFields)
    $uri        = "$graphBase/users?`$select=$encodedSel&`$top=100"

    if (-not [string]::IsNullOrWhiteSpace($ODataFilter)) {
        $encodedFilter = [uri]::EscapeDataString($ODataFilter)
        $uri += "&`$filter=$encodedFilter"
    }

    Write-Info "Querying Graph API..."

    do {
        $response = Invoke-GraphGet -Uri $uri

        foreach ($user in $response.value) {
            $users.Add($user)
            if ($users.Count -ge $Max) { return $users }
        }

        $uri = $response.'@odata.nextLink'
    } while ($uri -and $users.Count -lt $Max)

    return $users
}

# ─── Mode: delete users by UPN prefix (External ID only) ─────────────────────
if ($DeleteByPrefix) {
    # startsWith requires ConsistencyLevel: eventual + $count=true
    $deleteHeaders = $headers.Clone()
    $deleteHeaders["ConsistencyLevel"] = "eventual"

    # ── CountOnly: read @odata.count from the first page and exit ──────────
    if ($CountOnly) {
        $countUri      = "$graphBase/users?`$filter=startsWith(userPrincipalName,'$DeleteByPrefix')&`$select=id&`$top=1&`$count=true"
        $countResponse = Invoke-RestMethod -Method Get -Uri $countUri -Headers $deleteHeaders
        $total         = $countResponse.'@odata.count'
        $timestamp     = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
        Write-Success "[$timestamp] Users with prefix '$DeleteByPrefix': $total"
        exit 0
    }

    Write-Warn "⚠  DELETE MODE — External ID users with UPN prefix: '$DeleteByPrefix'"
    if ($WhatIf) { Write-Warn "   [WhatIf] No users will be deleted." }
    Write-Host ""

    $toDelete = [System.Collections.Generic.List[object]]::new()
    $uri      = "$graphBase/users?`$filter=startsWith(userPrincipalName,'$DeleteByPrefix')&`$select=id,userPrincipalName&`$top=999&`$count=true"

    Write-Info "Querying External ID for users with prefix '$DeleteByPrefix' (max $MaxUsers)..."

    do {
        $response = Invoke-RestMethod -Method Get -Uri $uri -Headers $deleteHeaders
        foreach ($u in $response.value) {
            $toDelete.Add($u)
            if ($toDelete.Count -ge $MaxUsers) { break }
        }
        $uri = $response.'@odata.nextLink'
    } while ($uri -and $toDelete.Count -lt $MaxUsers)

    if ($toDelete.Count -eq 0) {
        Write-Warn "No users found with prefix '$DeleteByPrefix'."
        exit 0
    }

    Write-Success "Found $($toDelete.Count) user(s) to delete."
    Write-Host ""

    if ($WhatIf) {
        $toDelete | ForEach-Object { Write-Warn "  [WhatIf] Would delete: $($_.id)  ($($_.userPrincipalName))" }
        Write-Host ""
        Write-Warn "═══════════════════════════════════════════════════════"
        Write-Warn "  [WhatIf] No changes were made."
        Write-Warn "  Remove -WhatIf to delete $($toDelete.Count) user(s)."
        Write-Warn "═══════════════════════════════════════════════════════"
        exit 0
    }

    $successCount = 0
    $failCount    = 0
    $total        = $toDelete.Count

    foreach ($u in $toDelete) {
        try {
            Invoke-GraphDelete -Uri "$graphBase/users/$($u.id)"
            $successCount++
            Write-Success "  ✓ [$successCount/$total] $($u.userPrincipalName)"
        }
        catch {
            Write-Err "  ✗ $($u.id)  ($($u.userPrincipalName))  – $_"
            $failCount++
        }
    }

    Write-Host ""
    if ($failCount -eq 0) {
        Write-Success "═══════════════════════════════════════════════════════"
        Write-Success "  Deleted : $successCount user(s)  |  Failed: $failCount"
        Write-Success "═══════════════════════════════════════════════════════"
    }
    else {
        Write-Warn "═══════════════════════════════════════════════════════"
        Write-Warn "  Deleted : $successCount user(s)  |  Failed: $failCount"
        Write-Warn "  Review errors above and re-run for failed users."
        Write-Warn "═══════════════════════════════════════════════════════"
    }

    exit 0
}

# ─── Mode: single user ────────────────────────────────────────────────────────
# Resolve UPN → Object ID
if ($UserUpn -and -not $UserId) {
    Write-Info "Resolving UPN: $UserUpn"
    try {
        # Encode the UPN for use as a path segment (/users/{upn})
        # # must be encoded as %23, @ as %40 to avoid OData/URI issues
        $encodedUpn = $UserUpn -replace "#", "%23" -replace "@", "%40"
        $resolved   = Invoke-GraphGet -Uri "$graphBase/users/$encodedUpn`?`$select=id,userPrincipalName"
        $UserId     = $resolved.id
        Write-Success "✓ Resolved Object ID: $UserId"
        Write-Host ""
    }
    catch {
        Write-Err "No user found with UPN '$UserUpn': $_"
        exit 1
    }
}

if ($UserId) {
    Write-Info "Fetching user: $UserId"

    try {
        $encodedSel = [uri]::EscapeDataString($selectFields)
        $user       = Invoke-GraphGet -Uri "$graphBase/users/$UserId`?`$select=$encodedSel"
    }
    catch {
        Write-Err "User not found or access denied."
        exit 1
    }

    $currentFlag = $user.$requireMigrationAttr
    Write-Host ""
    Write-Host "  Object ID          : $($user.id)"             -ForegroundColor White
    Write-Host "  UPN                : $($user.userPrincipalName)" -ForegroundColor White
    Write-Host "  Display Name       : $($user.displayName)"    -ForegroundColor White
    Write-Host "  Mail               : $($user.mail)"           -ForegroundColor White
    Write-Host "  RequiresMigration  : $currentFlag"            -ForegroundColor $(if ($currentFlag -eq $true) { "Yellow" } else { "Green" })
    Write-Host ""

    if ($SetFlag) {
        $newValue = ($SetFlag -eq "true")

        if ($WhatIf) {
            Write-Warn "[WhatIf] Would set ${requireMigrationAttr} = $newValue for user $UserId"
        }
        else {
            Write-Info "Setting ${requireMigrationAttr} = $newValue ..."
            $body = @{ $requireMigrationAttr = $newValue } | ConvertTo-Json
            Invoke-GraphPatch -Uri "$graphBase/users/$UserId" -Body $body
            Write-Success "✓ Flag updated successfully"
        }
    }

    exit 0
}

# ─── Mode: bulk query / update ────────────────────────────────────────────────

# Build OData filter
$odataFilter = switch ($Filter) {
    "true"   { "$requireMigrationAttr eq true" }
    "false"  { "$requireMigrationAttr eq false" }
    "notset" {
        # Graph does not support "eq null" for extension attrs – use NOT operator
        "NOT $requireMigrationAttr eq true AND NOT $requireMigrationAttr eq false"
    }
    "all"    { "" }
}

Write-Info "Filter mode : $Filter"
if ($odataFilter) { Write-Info "OData filter: $odataFilter" }
Write-Host ""

$users = Get-Users -ODataFilter $odataFilter -Max $MaxUsers

if ($users.Count -eq 0) {
    Write-Warn "No users found matching the filter."
    Write-Host ""
    exit 0
}

# ─── Display results ──────────────────────────────────────────────────────────
Write-Success "Found $($users.Count) user(s):"
Write-Host ""

$tableData = $users | ForEach-Object {
    $flag = $_.$requireMigrationAttr
    [PSCustomObject]@{
        ObjectId          = $_.id
        UPN               = $_.userPrincipalName
        DisplayName       = $_.displayName
        Mail              = $_.mail
        RequiresMigration = if ($null -eq $flag) { "(not set)" } else { "$flag" }
    }
}

$tableData | Format-Table -AutoSize | Out-String | ForEach-Object { Write-Host $_ }

# ─── Update flag (if requested) ───────────────────────────────────────────────
if ($SetFlag) {
    $newValue = ($SetFlag -eq "true")
    $action   = if ($WhatIf) { "Would update" } else { "Updating" }

    Write-Host ""
    Write-Info "$action ${requireMigrationAttr} → $newValue for $($users.Count) user(s)..."
    Write-Host ""

    $successCount = 0
    $failCount    = 0

    foreach ($user in $users) {
        $upn = $user.userPrincipalName

        if ($WhatIf) {
            Write-Warn "  [WhatIf] $($user.id)  ($upn)"
            continue
        }

        try {
            $body = @{ $requireMigrationAttr = $newValue } | ConvertTo-Json
            Invoke-GraphPatch -Uri "$graphBase/users/$($user.id)" -Body $body
            Write-Success "  ✓ $($user.id)  ($upn)"
            $successCount++
        }
        catch {
            Write-Err "  ✗ $($user.id)  ($upn)  – $_"
            $failCount++
        }
    }

    Write-Host ""
    if (-not $WhatIf) {
        if ($failCount -eq 0) {
            Write-Success "═══════════════════════════════════════════════════════"
            Write-Success "  Updated: $successCount user(s)  |  Failed: $failCount"
            Write-Success "═══════════════════════════════════════════════════════"
        }
        else {
            Write-Warn "═══════════════════════════════════════════════════════"
            Write-Warn "  Updated: $successCount user(s)  |  Failed: $failCount"
            Write-Warn "  Review errors above and re-run for failed users."
            Write-Warn "═══════════════════════════════════════════════════════"
        }
    }
    else {
        Write-Warn "═══════════════════════════════════════════════════════"
        Write-Warn "  [WhatIf] No changes were made."
        Write-Warn "  Remove -WhatIf to apply the changes."
        Write-Warn "═══════════════════════════════════════════════════════"
    }
}

Write-Host ""
