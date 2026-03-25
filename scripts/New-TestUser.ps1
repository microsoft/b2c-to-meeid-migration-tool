# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
<#
.SYNOPSIS
    Creates one or more test users in Entra External ID for migration testing.

.DESCRIPTION
    Creates users with an emailAddress identity and optionally sets the
    RequiresMigration flag. Reads tenant / credential configuration from
    the same appsettings JSON files used by the other migration scripts.

    The UPN is derived automatically from the email address following the
    External ID convention:  user_domain.com#EXT#@<tenantDomain>

.PARAMETER ConfigFile
    Path to the appsettings JSON file (relative to the console project directory).
    Default: appsettings.worker1.json

.PARAMETER Email
    Single user e-mail address to create.
    Mutually exclusive with -Prefix / -Count.

.PARAMETER DisplayName
    Display name for the user when using -Email.
    Default: derived from the local part of the e-mail address.

.PARAMETER Prefix
    Local-part prefix for bulk creation. Combined with -Domain and an
    incrementing number:  <Prefix><N>@<Domain>
    Example: -Prefix "testjit" -Domain "slider-inc.com" -Count 5
             → testjit1@slider-inc.com … testjit5@slider-inc.com
    Mutually exclusive with -Email.

.PARAMETER Domain
    E-mail domain used with -Prefix.
    Default: slider-inc.com

.PARAMETER Count
    Number of users to create when using -Prefix.
    Default: 1

.PARAMETER StartIndex
    First index to append when using -Prefix.
    Default: 1

.PARAMETER Password
    Password assigned to every created user.
    Default: TempP@ssw0rd!2026

.PARAMETER SetMigrationFlag
    Value to set for the RequiresMigration extension attribute.
    Accepted values: true | false | none  (none = do not set the attribute)
    Default: true

.PARAMETER AttributeName
    Override the extension attribute name for the migration flag.
    Default: derived from Migration.ExternalId.ExtensionAppId in config.

.PARAMETER WhatIf
    Preview the users that would be created without actually creating them.

.EXAMPLE
    # Create a single user with the migration flag set to true
    .\New-TestUser.ps1 -Email "testjitusse@slider-inc.com"

.EXAMPLE
    # Create a single user with the flag set to false
    .\New-TestUser.ps1 -Email "testjitusse@slider-inc.com" -SetMigrationFlag false

.EXAMPLE
    # Create 10 bulk test users  testjit1@slider-inc.com … testjit10@slider-inc.com
    .\New-TestUser.ps1 -Prefix "testjit" -Count 10

.EXAMPLE
    # Preview 5 users starting at index 20 without creating them
    .\New-TestUser.ps1 -Prefix "testjit" -Count 5 -StartIndex 20 -WhatIf

.EXAMPLE
    # Create users without setting the migration flag
    .\New-TestUser.ps1 -Prefix "testjit" -Count 3 -SetMigrationFlag none
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigFile = "appsettings.worker1.json",

    # ── Single-user mode ───────────────────────────────────────────────────────
    [Parameter(Mandatory = $false, ParameterSetName = "Single")]
    [string]$Email,

    [Parameter(Mandatory = $false, ParameterSetName = "Single")]
    [string]$DisplayName,

    # ── Bulk mode ─────────────────────────────────────────────────────────────
    [Parameter(Mandatory = $false, ParameterSetName = "Bulk")]
    [string]$Prefix = "testjit",

    [Parameter(Mandatory = $false, ParameterSetName = "Bulk")]
    [string]$Domain = "slider-inc.com",

    [Parameter(Mandatory = $false, ParameterSetName = "Bulk")]
    [int]$Count = 1,

    [Parameter(Mandatory = $false, ParameterSetName = "Bulk")]
    [int]$StartIndex = 1,

    # ── Common ────────────────────────────────────────────────────────────────
    [Parameter(Mandatory = $false)]
    [string]$Password = "TempP@ssw0rd!2026",

    [Parameter(Mandatory = $false)]
    [ValidateSet("true", "false", "none")]
    [string]$SetMigrationFlag = "true",

    [Parameter(Mandatory = $false)]
    [string]$AttributeName,

    [Parameter(Mandatory = $false)]
    [switch]$WhatIf
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
Write-Host "  B2C Migration Kit - Test User Creator"                -ForegroundColor Cyan
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

$tenantId       = $cfg.Migration.ExternalId.TenantId
$tenantDomain   = $cfg.Migration.ExternalId.TenantDomain
$clientId       = $cfg.Migration.ExternalId.AppRegistration.ClientId
$clientSecret   = $cfg.Migration.ExternalId.AppRegistration.ClientSecret
$extensionAppId = $cfg.Migration.ExternalId.ExtensionAppId

$missing = @()
if ([string]::IsNullOrWhiteSpace($tenantId))      { $missing += "Migration.ExternalId.TenantId" }
if ([string]::IsNullOrWhiteSpace($tenantDomain))  { $missing += "Migration.ExternalId.TenantDomain" }
if ([string]::IsNullOrWhiteSpace($clientId))      { $missing += "Migration.ExternalId.AppRegistration.ClientId" }
if ([string]::IsNullOrWhiteSpace($clientSecret))  { $missing += "Migration.ExternalId.AppRegistration.ClientSecret" }
if ([string]::IsNullOrWhiteSpace($extensionAppId)){ $missing += "Migration.ExternalId.ExtensionAppId" }

if ($missing.Count -gt 0) {
    Write-Err "Missing required configuration fields:"
    $missing | ForEach-Object { Write-Err "  - $_" }
    exit 1
}

# Determine migration attribute name
if (-not [string]::IsNullOrWhiteSpace($AttributeName)) {
    $migAttr = $AttributeName
}
else {
    $migAttr = $cfg.Migration.Import.MigrationAttributes.RequireMigrationTarget
    if ([string]::IsNullOrWhiteSpace($migAttr)) {
        $cleanAppId = $extensionAppId -replace "-", ""
        $migAttr    = "extension_${cleanAppId}_requiresMigration"
    }
}

Write-Success "✓ Configuration loaded"
Write-Info   "  Tenant          : $tenantId ($tenantDomain)"
Write-Info   "  Migration attr  : $migAttr"
if ($WhatIf) { Write-Warn "  [WhatIf mode – no users will be created]" }
Write-Host ""

# ─── Build list of users to create ───────────────────────────────────────────
$usersToCreate = [System.Collections.Generic.List[hashtable]]::new()

if ($PSCmdlet.ParameterSetName -eq "Single" -or $Email) {
    if ([string]::IsNullOrWhiteSpace($Email)) {
        Write-Err "Provide -Email or use -Prefix / -Count for bulk creation."
        exit 1
    }
    $dn = if ($DisplayName) { $DisplayName } else { ($Email -split "@")[0] }
    $usersToCreate.Add(@{ Email = $Email; DisplayName = $dn })
}
else {
    for ($i = $StartIndex; $i -lt ($StartIndex + $Count); $i++) {
        $mail = "${Prefix}${i}@${Domain}"
        $usersToCreate.Add(@{ Email = $mail; DisplayName = "${Prefix} ${i}" })
    }
}

Write-Info "Users to create: $($usersToCreate.Count)"
Write-Host ""

# ─── Acquire access token ─────────────────────────────────────────────────────
Write-Info "Acquiring access token..."

try {
    $tokenResponse = Invoke-RestMethod -Method Post `
        -Uri "https://login.microsoftonline.com/$tenantId/oauth2/v2.0/token" `
        -Body @{
            grant_type    = "client_credentials"
            client_id     = $clientId
            client_secret = $clientSecret
            scope         = "https://graph.microsoft.com/.default"
        } `
        -ContentType "application/x-www-form-urlencoded"

    $accessToken = $tokenResponse.access_token
}
catch {
    Write-Err "Failed to acquire access token: $_"
    exit 1
}

Write-Success "✓ Access token acquired"
Write-Host ""

$headers   = @{ Authorization = "Bearer $accessToken"; "Content-Type" = "application/json" }
$graphBase = "https://graph.microsoft.com/v1.0"

# ─── Helper: build UPN from email ─────────────────────────────────────────────
function Get-ExternalIdUpn {
    param([string]$EmailAddress)
    # External ID convention: replace @ with _ then append #EXT#@<tenantDomain>
    return ($EmailAddress -replace "@", "_") + "#EXT#@$tenantDomain"
}

# ─── Create users ─────────────────────────────────────────────────────────────
$successCount = 0
$skipCount    = 0
$failCount    = 0

foreach ($u in $usersToCreate) {
    $email = $u.Email
    $dn    = $u.DisplayName
    $upn   = Get-ExternalIdUpn -EmailAddress $email

    if ($WhatIf) {
        Write-Warn "  [WhatIf] Would create: $email  (UPN: $upn)"
        if ($SetMigrationFlag -ne "none") { Write-Warn "            ${migAttr} = $SetMigrationFlag" }
        continue
    }

    try {
        $body = [ordered]@{
            accountEnabled    = $true
            displayName       = $dn
            userPrincipalName = $upn
            passwordProfile   = @{
                forceChangePasswordNextSignIn = $false
                password                      = $Password
            }
            passwordPolicies = "DisablePasswordExpiration"
            identities       = @(
                @{
                    signInType       = "emailAddress"
                    issuer           = $tenantDomain
                    issuerAssignedId = $email
                }
            )
        }

        if ($SetMigrationFlag -ne "none") {
            $body[$migAttr] = ($SetMigrationFlag -eq "true")
        }

        $result = Invoke-RestMethod -Method Post `
            -Uri "$graphBase/users" `
            -Headers $headers `
            -Body ($body | ConvertTo-Json -Depth 5)

        Write-Success "  ✓ $email  →  $($result.id)"
        $successCount++
    }
    catch {
        # Check for 409 Conflict (user already exists)
        $statusCode = $_.Exception.Response.StatusCode.value__
        if ($statusCode -eq 409) {
            Write-Warn "  ⚠ $email  – already exists (skipped)"
            $skipCount++
        }
        else {
            $errBody = $null
            try { $errBody = ($_.ErrorDetails.Message | ConvertFrom-Json).error.message } catch {}
            Write-Err "  ✗ $email  – $($errBody ?? $_)"
            $failCount++
        }
    }
}

# ─── Summary ─────────────────────────────────────────────────────────────────
Write-Host ""

if ($WhatIf) {
    Write-Warn "═══════════════════════════════════════════════════════"
    Write-Warn "  [WhatIf] No users were created."
    Write-Warn "  Remove -WhatIf to apply the changes."
    Write-Warn "═══════════════════════════════════════════════════════"
}
elseif ($failCount -eq 0) {
    Write-Success "═══════════════════════════════════════════════════════"
    Write-Success "  Created : $successCount   Skipped : $skipCount   Failed : $failCount"
    if ($SetMigrationFlag -ne "none") {
        Write-Success "  ${migAttr} = $SetMigrationFlag"
    }
    Write-Success "═══════════════════════════════════════════════════════"
}
else {
    Write-Warn "═══════════════════════════════════════════════════════"
    Write-Warn "  Created : $successCount   Skipped : $skipCount   Failed : $failCount"
    Write-Warn "  Review errors above."
    Write-Warn "═══════════════════════════════════════════════════════"
}

Write-Host ""
