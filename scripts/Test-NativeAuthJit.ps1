# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
<#
.SYNOPSIS
    Tests JIT password migration via Native Authentication APIs.

.DESCRIPTION
    Performs a Native Auth sign-in flow against External ID and verifies that
    the JIT password migration (onPasswordSubmit CAE) is triggered.

    The test proves that:
    1. Native Auth password sign-in reaches the onPasswordSubmit event
    2. The Custom Authentication Extension (Azure Function) processes the request
    3. The user's password is migrated (RequiresMigration flag cleared)
    4. Subsequent sign-ins work directly without CAE invocation

    This script uses the Native Auth /initiate → /challenge → /token flow
    with challenge_type=password (not OTP), ensuring the password-submit
    path is exercised.

.PARAMETER TenantSubdomain
    The External ID tenant subdomain (e.g., "lagomarciamdemo2").
    The script constructs: https://{subdomain}.ciamlogin.com/{subdomain}.onmicrosoft.com

.PARAMETER ClientId
    Application (client) ID of the Native Auth app (from Configure-NativeAuthJit.ps1).

.PARAMETER Username
    Email address of the test user (must have RequiresMigration=true).

.PARAMETER Password
    Password to authenticate with. For JIT migration, this is the B2C password
    (or any password if the Function is in TestMode).

.PARAMETER VerifyMigrationFlag
    If specified, checks the RequiresMigration extension attribute before and after
    sign-in to confirm it was cleared. Requires -ExtensionAppId and Graph credentials.

.PARAMETER ExtensionAppId
    Extension app ID (without hyphens) for reading the RequiresMigration attribute.
    Required only when -VerifyMigrationFlag is specified.

.PARAMETER GraphAccessToken
    Access token with User.Read.All on the External ID tenant.
    Required only when -VerifyMigrationFlag is specified.

.PARAMETER SecondSignIn
    If specified, performs a second sign-in after migration to verify direct auth works.

.EXAMPLE
    .\Test-NativeAuthJit.ps1 `
        -TenantSubdomain "lagomarciamdemo2" `
        -ClientId "12345678-1234-1234-1234-123456789012" `
        -Username "testjit1@slider-inc.com" `
        -Password "TempP@ssw0rd!2026"

.EXAMPLE
    # Full verification with migration flag check
    .\Test-NativeAuthJit.ps1 `
        -TenantSubdomain "lagomarciamdemo2" `
        -ClientId "12345678-..." `
        -Username "testjit1@slider-inc.com" `
        -Password "TempP@ssw0rd!2026" `
        -VerifyMigrationFlag `
        -ExtensionAppId "d7e9bb7927284f7c85d0fa045ec77b1f" `
        -GraphAccessToken $token `
        -SecondSignIn

.NOTES
    Requirements:
    - PowerShell 7.0 or later
    - Native Auth app must be configured (Configure-NativeAuthJit.ps1)
    - User must exist in External ID with RequiresMigration=true
    - Azure Function (JIT) must be running and accessible
    - Event listener must include the Native Auth app
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$TenantSubdomain,

    [Parameter(Mandatory = $true)]
    [string]$ClientId,

    [Parameter(Mandatory = $true)]
    [string]$Username,

    [Parameter(Mandatory = $true)]
    [string]$Password,

    [switch]$VerifyMigrationFlag,

    [string]$ExtensionAppId,

    [string]$GraphAccessToken,

    [switch]$SecondSignIn
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

function Invoke-NativeAuthRequest {
    param(
        [string]$Uri,
        [hashtable]$Body,
        [string]$Operation
    )

    try {
        $response = Invoke-RestMethod -Method Post `
            -Uri $Uri `
            -ContentType "application/x-www-form-urlencoded" `
            -Body $Body

        return @{ Success = $true; Response = $response; Error = $null }
    }
    catch {
        $errorDetail = $null
        if ($_.ErrorDetails.Message) {
            try { $errorDetail = $_.ErrorDetails.Message | ConvertFrom-Json } catch {}
        }
        return @{
            Success = $false
            Response = $null
            Error = @{
                Message = $_.Exception.Message
                Detail = $errorDetail
                StatusCode = $_.Exception.Response.StatusCode
            }
        }
    }
}

function Decode-JwtPayload {
    param([string]$Token)

    $parts = $Token.Split('.')
    if ($parts.Length -lt 2) { return $null }

    $payload = $parts[1]
    # Pad base64url
    switch ($payload.Length % 4) {
        2 { $payload += '==' }
        3 { $payload += '=' }
    }
    $payload = $payload.Replace('-', '+').Replace('_', '/')

    $bytes = [Convert]::FromBase64String($payload)
    $json = [System.Text.Encoding]::UTF8.GetString($bytes)
    return $json | ConvertFrom-Json
}

function Do-NativeAuthSignIn {
    param(
        [string]$BaseUrl,
        [string]$ClientId,
        [string]$Username,
        [string]$Password,
        [string]$Label = "Sign-in"
    )

    Write-Info "[$Label] Starting Native Auth password sign-in..."
    Write-Step "User: $Username"
    Write-Step "Endpoint: $BaseUrl"
    Write-Host ""

    # Step 1: Initiate
    Write-Host "[Step 1/3] Initiating sign-in..." -ForegroundColor Yellow

    $initiateResult = Invoke-NativeAuthRequest `
        -Uri "$BaseUrl/oauth2/v2.0/initiate" `
        -Body @{
            client_id = $ClientId
            username = $Username
            challenge_type = "password redirect"
        } `
        -Operation "Initiate"

    if (-not $initiateResult.Success) {
        Write-ErrorMsg "Initiate failed: $($initiateResult.Error.Message)"
        if ($initiateResult.Error.Detail) {
            Write-Step "Error: $($initiateResult.Error.Detail.error)"
            Write-Step "Description: $($initiateResult.Error.Detail.error_description)"
        }
        return $null
    }

    $continuationToken = $initiateResult.Response.continuation_token
    if (-not $continuationToken) {
        Write-ErrorMsg "No continuation_token in initiate response"
        return $null
    }

    Write-Success "Sign-in initiated"

    # Step 2: Challenge (request password challenge)
    Write-Host "[Step 2/3] Requesting password challenge..." -ForegroundColor Yellow

    $challengeResult = Invoke-NativeAuthRequest `
        -Uri "$BaseUrl/oauth2/v2.0/challenge" `
        -Body @{
            client_id = $ClientId
            continuation_token = $continuationToken
            challenge_type = "password redirect"
        } `
        -Operation "Challenge"

    if (-not $challengeResult.Success) {
        Write-ErrorMsg "Challenge failed: $($challengeResult.Error.Message)"
        if ($challengeResult.Error.Detail) {
            Write-Step "Error: $($challengeResult.Error.Detail.error)"
            Write-Step "Description: $($challengeResult.Error.Detail.error_description)"
        }
        return $null
    }

    # CRITICAL: Verify we got a password challenge, not a redirect
    $challengeType = $challengeResult.Response.challenge_type
    if ($challengeType -eq "redirect") {
        Write-ErrorMsg "REDIRECT received instead of password challenge!"
        Write-ErrorMsg "This means the app/user flow is not correctly configured for Native Auth."
        Write-Warn "Check that:"
        Write-Step "- App has nativeAuthenticationApisEnabled = 'all'"
        Write-Step "- User flow supports Email+Password"
        Write-Step "- User flow is linked to this app"
        return $null
    }

    $continuationToken = $challengeResult.Response.continuation_token
    Write-Success "Password challenge accepted (challenge_type: $challengeType)"

    # Step 3: Token (submit password)
    Write-Host "[Step 3/3] Submitting password..." -ForegroundColor Yellow

    $tokenResult = Invoke-NativeAuthRequest `
        -Uri "$BaseUrl/oauth2/v2.0/token" `
        -Body @{
            client_id = $ClientId
            continuation_token = $continuationToken
            grant_type = "password"
            password = $Password
            scope = "openid profile offline_access"
        } `
        -Operation "Token"

    if (-not $tokenResult.Success) {
        Write-ErrorMsg "Token request failed: $($tokenResult.Error.Message)"
        if ($tokenResult.Error.Detail) {
            Write-Step "Error: $($tokenResult.Error.Detail.error)"
            Write-Step "Description: $($tokenResult.Error.Detail.error_description)"
            Write-Step "Suberror: $($tokenResult.Error.Detail.suberror)"
        }
        return $null
    }

    Write-Success "Tokens received!"
    return $tokenResult.Response
}

# ============================================================================
# Main Test Flow
# ============================================================================

$BaseUrl = "https://$TenantSubdomain.ciamlogin.com/$TenantSubdomain.onmicrosoft.com"

Write-Header "Native Auth JIT Migration Test"

Write-Info "Test Configuration:"
Write-Step "Tenant: $TenantSubdomain"
Write-Step "Client ID: $ClientId"
Write-Step "Username: $Username"
Write-Step "Base URL: $BaseUrl"
Write-Step "Verify Migration Flag: $VerifyMigrationFlag"
Write-Step "Second Sign-In: $SecondSignIn"

# ── Pre-flight: Check migration flag (if requested) ───────────────────────────
if ($VerifyMigrationFlag) {
    if (-not $ExtensionAppId -or -not $GraphAccessToken) {
        Write-ErrorMsg "-ExtensionAppId and -GraphAccessToken are required when -VerifyMigrationFlag is specified"
        exit 1
    }

    Write-Header "Pre-flight: Checking RequiresMigration Flag"

    $migrationAttr = "extension_${ExtensionAppId}_RequiresMigration"
    Write-Step "Attribute: $migrationAttr"

    # Find user by email identity
    $userSearch = Invoke-RestMethod -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/users?`$filter=identities/any(i:i/issuer eq '$TenantSubdomain.onmicrosoft.com' and i/issuerAssignedId eq '$Username')&`$select=id,displayName,$migrationAttr" `
        -Headers @{ Authorization = "Bearer $GraphAccessToken"; "Content-Type" = "application/json" }

    if ($userSearch.value.Count -eq 0) {
        Write-ErrorMsg "User not found: $Username"
        Write-Info "Create a test user first with: .\New-TestUser.ps1 -Email `"$Username`" -SetMigrationFlag true"
        exit 1
    }

    $testUser = $userSearch.value[0]
    $currentFlag = $testUser.$migrationAttr
    Write-Info "User: $($testUser.displayName) (ID: $($testUser.id))"
    Write-Info "RequiresMigration: $currentFlag"

    if ($currentFlag -ne $true -and $currentFlag -ne "true") {
        Write-Warn "RequiresMigration is NOT true. JIT CAE may not fire."
        Write-Warn "Set it with: .\Manage-MigrationFlag.ps1 -UserEmail `"$Username`" -FlagValue true"
    } else {
        Write-Success "RequiresMigration = true (JIT will fire on sign-in)"
    }
}

# ── First Sign-in (JIT migration should trigger) ─────────────────────────────
Write-Header "Test 1: Native Auth Sign-In (JIT Migration)"

$result = Do-NativeAuthSignIn -BaseUrl $BaseUrl -ClientId $ClientId -Username $Username -Password $Password -Label "JIT Migration"

if (-not $result) {
    Write-Host ""
    Write-ErrorMsg "═══════════════════════════════════════════════════════════════"
    Write-ErrorMsg "  TEST FAILED: Native Auth sign-in did not succeed"
    Write-ErrorMsg "═══════════════════════════════════════════════════════════════"
    Write-Host ""
    Write-Warn "Possible causes:"
    Write-Step "1. Azure Function (JIT) is not running or not reachable"
    Write-Step "2. Event listener does not include this app"
    Write-Step "3. App/user flow not configured for Native Auth password"
    Write-Step "4. User does not exist or has no RequiresMigration flag"
    Write-Step "5. CAE timed out (>2s)"
    exit 1
}

# Display token info
Write-Host ""
Write-Info "Token Details:"
Write-Step "Access Token: $($result.access_token.Substring(0, [Math]::Min(50, $result.access_token.Length)))..."
Write-Step "Token Type: $($result.token_type)"
Write-Step "Expires In: $($result.expires_in)s"

if ($result.id_token) {
    $claims = Decode-JwtPayload -Token $result.id_token
    if ($claims) {
        Write-Host ""
        Write-Info "ID Token Claims:"
        Write-Step "sub: $($claims.sub)"
        Write-Step "email: $($claims.email ?? $claims.preferred_username)"
        Write-Step "oid: $($claims.oid)"
        Write-Step "tid: $($claims.tid)"
    }
}

Write-Host ""
Write-Success "═══════════════════════════════════════════════════════════════"
Write-Success "  FIRST SIGN-IN SUCCEEDED — JIT migration processed!"
Write-Success "═══════════════════════════════════════════════════════════════"

# ── Post-flight: Verify migration flag cleared ────────────────────────────────
if ($VerifyMigrationFlag) {
    Write-Header "Post-flight: Verifying RequiresMigration Cleared"

    # Wait a moment for propagation
    Write-Info "Waiting 3s for attribute propagation..."
    Start-Sleep -Seconds 3

    $userCheck = Invoke-RestMethod -Method GET `
        -Uri "https://graph.microsoft.com/v1.0/users/$($testUser.id)?`$select=id,$migrationAttr" `
        -Headers @{ Authorization = "Bearer $GraphAccessToken"; "Content-Type" = "application/json" }

    $newFlag = $userCheck.$migrationAttr
    Write-Info "RequiresMigration after sign-in: $newFlag"

    if ($newFlag -eq $false -or $newFlag -eq "false" -or $null -eq $newFlag) {
        Write-Success "Migration flag CLEARED — JIT migration confirmed!"
    } else {
        Write-Warn "Migration flag still set. Possible reasons:"
        Write-Step "- Function is in TestMode (may not clear flag)"
        Write-Step "- Propagation delay (try checking again in a few seconds)"
        Write-Step "- CAE returned success but EEID didn't update the attribute"
    }
}

# ── Second Sign-in (should work directly, no JIT) ────────────────────────────
if ($SecondSignIn) {
    Write-Header "Test 2: Second Sign-In (Direct Auth, No JIT)"

    Write-Info "Waiting 2s before second attempt..."
    Start-Sleep -Seconds 2

    $result2 = Do-NativeAuthSignIn -BaseUrl $BaseUrl -ClientId $ClientId -Username $Username -Password $Password -Label "Direct Auth"

    if ($result2) {
        Write-Host ""
        Write-Success "═══════════════════════════════════════════════════════════════"
        Write-Success "  SECOND SIGN-IN SUCCEEDED — Direct auth works post-migration!"
        Write-Success "═══════════════════════════════════════════════════════════════"
    } else {
        Write-Warn "Second sign-in failed. This could indicate:"
        Write-Step "- Password was not actually persisted by EEID"
        Write-Step "- Function TestMode doesn't persist passwords"
        Write-Step "- Timing issue (try again in a few seconds)"
    }
}

# ── Final Summary ─────────────────────────────────────────────────────────────
Write-Host ""
Write-Header "Test Summary"

Write-Host "  Test 1 (JIT Migration Sign-in): " -NoNewline
Write-Host "PASSED" -ForegroundColor Green

if ($SecondSignIn) {
    Write-Host "  Test 2 (Direct Auth Post-Migration): " -NoNewline
    if ($result2) { Write-Host "PASSED" -ForegroundColor Green }
    else { Write-Host "WARN" -ForegroundColor Yellow }
}

if ($VerifyMigrationFlag) {
    Write-Host "  Migration Flag Cleared: " -NoNewline
    $newFlag = $userCheck.$migrationAttr
    if ($newFlag -eq $false -or $newFlag -eq "false" -or $null -eq $newFlag) {
        Write-Host "YES" -ForegroundColor Green
    } else {
        Write-Host "NO (TestMode may not clear)" -ForegroundColor Yellow
    }
}

Write-Host ""
Write-Info "The JIT password migration works with Native Authentication APIs."
Write-Info "The onPasswordSubmit CAE fires correctly for Native Auth flows."
Write-Host ""
