# B2C Migration Kit - Developer Guide

This comprehensive guide provides detailed information for developers implementing, customizing, and operating the B2C to External ID Migration Kit.

## Table of Contents

- [Architecture Overview](#architecture-overview)
- [Project Structure](#project-structure)
- [Configuration Guide](#configuration-guide)
- [Development Workflow](#development-workflow)
  - [Local Development Setup](#local-development-setup)
  - [Building the Solution](#building-the-solution)
  - [Running Tests](#running-tests)
  - [Debugging JIT Function with ngrok](#debugging-jit-function-with-ngrok)
- [Attribute Mapping Configuration](#attribute-mapping-configuration)
- [Import Audit Logs](#import-audit-logs)
- [Testing Strategy](#testing-strategy)
- [Deployment Guide](#deployment-guide)
- [Operations & Monitoring](#operations--monitoring)
- [Security Best Practices](#security-best-practices)
- [Troubleshooting](#troubleshooting)

## Overview and Current Focus

> **📋 IMPLEMENTATION STATUS**: This repository is focused on exemplifying the implementation of the [Just-In-Time password migration public preview](https://learn.microsoft.com/en-us/entra/external-id/customers/how-to-migrate-passwords-just-in-time?tabs=graph). The current implementation provides working examples of export, import, and JIT authentication functions that developers can use as a reference.
>
> **Future Roadmap**: Automated deployment aligned with Secure Future Initiative (SFI) standards, including Bicep/Terraform templates for infrastructure provisioning, is planned for upcoming releases. The current focus is on providing validated migration patterns and code examples rather than production automation tooling.

## Architecture Overview

### Design Principles

The migration kit follows the SFI-Aligned Modular Architecture pattern with these key principles:

1. **Separation of Concerns**: Business logic in Core library, hosting in Console/Function
2. **Dependency Injection**: All services registered via DI for testability
3. **Idempotency**: All operations can be safely retried
4. **Observability**: Comprehensive telemetry and structured logging
5. **Security**: SFI-compliant design patterns for future production deployment

### Component Architecture

```
B2CMigrationKit.Core/
├── Abstractions/          # Service interfaces
├── Models/                # Domain models
├── Configuration/         # Configuration classes
├── Services/
│   ├── Infrastructure/    # Azure service clients
│   ├── Observability/     # Telemetry services
│   └── Orchestrators/     # Migration orchestrators
└── Extensions/            # DI registration

B2CMigrationKit.Console/   # CLI for local operations
B2CMigrationKit.Function/  # Azure Function for JIT & sync
```

## Project Structure

### Core Library (`B2CMigrationKit.Core`)

**Abstractions Layer**
- `IOrchestrator<T>` - Base interface for orchestration
- `IGraphClient` - Microsoft Graph operations
- `IBlobStorageClient` - Blob Storage operations
- `IQueueClient` - Queue Storage operations
- `ITelemetryService` - Telemetry operations
- `ICredentialManager` - Multi-app credential rotation
- `IAuthenticationService` - Credential validation

**Models**
- `UserProfile` - User identity model
- `ExecutionResult` - Operation result
- `BatchResult` - Batch operation result
- `PagedResult<T>` - Paged API results
- `MigrationStatus` - Migration state enum
- `RunSummary` - Execution metrics

**Services**

*Infrastructure Services*
- `GraphClient` - Implements IGraphClient with Polly retry policies
- `BlobStorageClient` - Blob operations with Managed Identity
- `QueueClient` - Queue operations for profile sync *(not implemented)*
- `CredentialManager` - Round-robin credential management
- `AuthenticationService` - ROPC-based credential validation

*Orchestrators*
- `ExportOrchestrator` - B2C user export
- `ImportOrchestrator` - External ID user import
- `JitMigrationService` - JIT authentication and migration
- `ProfileSyncService` - Async profile synchronization *(not implemented)*

## Configuration Guide

### Configuration Structure

The toolkit uses hierarchical configuration with `MigrationOptions` as the root:

```json
{
  "Migration": {
    "B2C": { ... },
    "ExternalId": { ... },
    "Storage": { ... },
    "Telemetry": { ... },
    "Retry": { ... },
    "BatchSize": 100
  }
}
```

### B2C Configuration

```json
"B2C": {
  "TenantId": "your-b2c-tenant-id",
  "TenantDomain": "yourtenant.onmicrosoft.com",
  "RopcPolicyName": "B2C_1_ROPC",
  "AppRegistration": {
    "ClientId": "app-id-1",
    "ClientSecretName": "B2CAppSecret1",
    "Name": "B2C App 1",
    "Enabled": true
  },
  "Scopes": [ "https://graph.microsoft.com/.default" ]
}
```

**App Registration Requirements:**
- **Permissions**: `Directory.Read.All` (for export)
- **Authentication**: Client credentials flow
- **Secrets**: Use client secrets directly in configuration for local development
- **Scaling**: Deploy multiple instances with different app registrations on different IPs

### External ID Configuration

```json
"ExternalId": {
  "TenantId": "your-external-id-tenant-id",
  "TenantDomain": "yourtenant.onmicrosoft.com",
  "ExtensionAppId": "00000000000000000000000000000000",
  "AppRegistration": {
    "ClientId": "app-id-1",
    "ClientSecretName": "ExternalIdAppSecret1",
    "Name": "External ID App 1",
    "Enabled": true
  },
  "PasswordPolicy": {
    "MinLength": 8,
    "RequireUppercase": true,
    "RequireLowercase": true,
    "RequireDigit": true,
    "RequireSpecialCharacter": true
  }
}
```

**App Registration Requirements:**
- **Permissions**: `User.ReadWrite.All`, `Directory.ReadWrite.All` (for import)
- **Extension App ID**: Application ID (without hyphens) for extension attributes
- **Scaling**: Deploy multiple instances with different app registrations on different IPs

### Storage Configuration

```json
"Storage": {
  "ConnectionStringOrUri": "https://yourstorage.blob.core.windows.net",
  "ExportContainerName": "user-exports",
  "ProfileSyncQueueName": "profile-updates",  // For future profile sync feature
  "UseManagedIdentity": true
}
```

**Required Roles:**
- Console/Function Managed Identity needs:
  - `Storage Blob Data Contributor`
  - `Storage Queue Data Contributor`

### Retry Configuration

```json
"Retry": {
  "MaxRetries": 5,
  "InitialDelayMs": 1000,
  "MaxDelayMs": 30000,
  "BackoffMultiplier": 2.0,
  "UseRetryAfterHeader": true,
  "OperationTimeoutSeconds": 120
}
```

### Telemetry Configuration

The toolkit supports dual telemetry output: console logging (local development) and Application Insights (production monitoring).

```json
"Telemetry": {
  "Enabled": true,
  "UseConsoleLogging": true,
  "UseApplicationInsights": false,
  "ConnectionString": "",
  "SamplingPercentage": 100.0,
  "TrackDependencies": true,
  "TrackExceptions": true
}
```

**Configuration Options:**
- `Enabled` - Master switch for all telemetry
- `UseConsoleLogging` - Write telemetry to console (recommended for local development)
- `UseApplicationInsights` - Send telemetry to Azure App Insights (production)
- `ConnectionString` - App Insights connection string (required when UseApplicationInsights=true)
- `SamplingPercentage` - Sampling rate (1.0-100.0) to reduce costs
- `TrackDependencies` - Track HTTP calls, database queries
- `TrackExceptions` - Track unhandled exceptions

**Common Scenarios:**

*Local Development (Console Only):*
```json
{
  "UseConsoleLogging": true,
  "UseApplicationInsights": false
}
```

*Production Monitoring:*
```json
{
  "UseConsoleLogging": false,
  "UseApplicationInsights": true,
  "ConnectionString": "InstrumentationKey=...;IngestionEndpoint=https://..."
}
```

*Cost Optimization (10% sampling):*
```json
{
  "UseApplicationInsights": true,
  "SamplingPercentage": 10.0
}
```

**Telemetry Metrics:**
- Export: `export.storage.total.bytes`, `export.throughput.users.per.second`
- Import: `import.graph.api.calls`, `import.blob.read.bytes`
- JIT: `JITAuth.PasswordValidated`, `JITAuth.MigrationSuccess`

## Development Workflow

### Local Development Setup

1. **Install Prerequisites**
   ```bash
   # .NET 8.0 SDK
   dotnet --version  # Should be 8.0+

   # Azure CLI (for authentication)
   az login
   ```

2. **Configure Local Settings**
   
   > **Important:** For local development without Key Vault, use `appsettings.local.example.json` as your template (not `appsettings.json`). The local example uses `ClientSecret` with direct secret values, while `appsettings.json` uses `ClientSecretName` which requires Key Vault.
   
   ```bash
   cd src/B2CMigrationKit.Console
   cp appsettings.local.example.json appsettings.Development.json
   # Edit appsettings.Development.json with your settings
   ```
   
   **Configuration patterns:**
   - **Local development (no Key Vault):** Use `ClientSecret` with the actual secret value
   - **Production (with Key Vault):** Use `ClientSecretName` with the Key Vault secret name

3. **Run Export Locally**
   ```powershell
   # From repository root - use the automation script
   .\scripts\Start-LocalExport.ps1 -VerboseLogging
   ```
   
   The script automatically:
   - Checks and starts Azurite if needed
   - Creates required storage containers
   - Builds the console application
   - Runs the export operation
   
   **Manual alternative** (requires Azurite running separately):
   ```powershell
   cd src\B2CMigrationKit.Console
   dotnet run -- export --config appsettings.Development.json --verbose
   ```

### Building the Solution

```bash
# Build all projects
dotnet build

# Build specific project
dotnet build src/B2CMigrationKit.Core

# Build for release
dotnet build -c Release
```


### JIT (Just-In-Time) Migration Implementation

⏱️ **Quick Start Time:** 15 minutes to running local test

The JIT authentication function integrates with External ID Custom Authentication Extension to migrate user passwords during their first login attempt. This section covers the complete implementation from local development to production deployment.

---

#### Prerequisites

**Required Tools:**
- .NET 8+ SDK
- Azure Functions Core Tools v4 (`func --version`)
- ngrok (free tier: [ngrok.com](https://ngrok.com))
- PowerShell 7+
- OpenSSL (for RSA key generation)

**Required Access:**
- Azure AD B2C tenant with test users
- External ID tenant with admin access
- Test users with known passwords

---

#### Understanding JIT Trigger Mechanism

**Critical Requirement:** External ID ONLY triggers JIT migration when:
1. User enters password that **does NOT match** stored password in External ID
2. AND `extension_<appId>_RequiresMigration == true`

**Why This Matters:**

During the bulk import phase, `ImportOrchestrator` generates **unique 16-character random passwords** for each user. These are **NOT** the user's real B2C passwords. This intentional mismatch ensures password validation fails on first login, triggering the JIT migration flow.

**User Login Flow:**

```
┌─────────────────────────────────────────────────────────────────┐
│                     Import Phase                                │
├─────────────────────────────────────────────────────────────────┤
│  B2C User Password: "MyRealPassword123!"                        │
│                                                                 │
│  ImportOrchestrator generates:                                  │
│  Random Password: "xK9#mP2qL8@vN4tR" (16 chars, unique)         │
│                                                                 │
│  External ID User Created With:                                 │
│  - Username: user@domain.com                                    │
│  - Password: "xK9#mP2qL8@vN4tR" (NOT the real B2C password)     │
│  - RequiresMigration: true                                      │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                   First Login (JIT Triggered)                   │
├─────────────────────────────────────────────────────────────────┤
│  User enters: "MyRealPassword123!" (real B2C password)          │
│                                                                 │
│  External ID compares:                                          │
│  "MyRealPassword123!" ≠ "xK9#mP2qL8@vN4tR" → MISMATCH           │
│                                                                 │
│  AND RequiresMigration == true → JIT TRIGGERS                    │
│                                                                 │
│  Custom Extension Called:                                       │
│  1. Validates "MyRealPassword123!" against B2C ROPC ✓           │
│  2. Updates External ID password to "MyRealPassword123!"        │
│  3. Sets RequiresMigration = false (migration complete)         │
│  4. User login succeeds                                         │
└─────────────────────────────────────────────────────────────────┘

┌─────────────────────────────────────────────────────────────────┐
│                Second Login (Normal Flow)                       │
├─────────────────────────────────────────────────────────────────┤
│  User enters: "MyRealPassword123!"                              │
│                                                                 │
│  External ID compares:                                          │
│  "MyRealPassword123!" == "MyRealPassword123!" → MATCH           │
│                                                                 │
│  Normal authentication → NO JIT CALL                            │
│  Login succeeds immediately                                     │
└─────────────────────────────────────────────────────────────────┘
```

**Password Generation Implementation:**

Located in `ImportOrchestrator.cs` (Lines 598-638):

```csharp
private string GenerateRandomPassword()
{
    // 16-character password with guaranteed complexity
    const int length = 16;
    const string uppercase = "ABCDEFGHIJKLMNOPQRSTUVWXYZ";
    const string lowercase = "abcdefghijklmnopqrstuvwxyz";
    const string digits = "0123456789";
    const string special = "!@#$%^&*()-_=+[]{}|;:,.<>?";
    
    var password = new StringBuilder();
    
    // Guarantee at least one of each character type
    password.Append(uppercase[Random.Shared.Next(uppercase.Length)]);
    password.Append(lowercase[Random.Shared.Next(lowercase.Length)]);
    password.Append(digits[Random.Shared.Next(digits.Length)]);
    password.Append(special[Random.Shared.Next(special.Length)]);
    
    // Fill remaining characters
    string allChars = uppercase + lowercase + digits + special;
    for (int i = 4; i < length; i++)
    {
        password.Append(allChars[Random.Shared.Next(allChars.Length)]);
    }
    
    // Shuffle to prevent patterns
    return new string(password.ToString().ToCharArray()
        .OrderBy(x => Random.Shared.Next()).ToArray());
}
```

**Key Characteristics:**
- ✅ **Length:** 16 characters (exceeds most complexity requirements)
- ✅ **Complexity:** Guaranteed 1 uppercase + 1 lowercase + 1 digit + 1 special
- ✅ **Uniqueness:** Fresh generation for each user (not derived from B2C data)
- ✅ **Randomness:** Shuffled to prevent predictable patterns
- ✅ **Purpose:** Ensures password mismatch to trigger JIT on first login

---

#### JIT Function Local Setup

**Step 1: Generate RSA Key Pair (5 minutes)**

**Option A: Use automation script (recommended)**
```powershell
.\scripts\New-JitRsaKeyPair.ps1 -OutputPath ".\B2C\local-keys"
```

**Option B: Manual with OpenSSL**
```bash
# Generate private key (2048-bit RSA)
openssl genrsa -out private_key.pem 2048

# Extract public key
openssl rsa -in private_key.pem -pubout -out public_key.pem
```

**Verify keys created:**
```powershell
Get-ChildItem .\B2C\local-keys\

# Expected output:
# private_key.pem  (RSA private key - NEVER commit to Git)
# public_key.pem   (RSA public key - safe to share)
```

---

**Step 2: Configure local.settings.json**

Create or update `src/B2CMigrationKit.Function/local.settings.json`:

```json
{
  "IsEncrypted": false,
  "Values": {
    "AzureWebJobsStorage": "UseDevelopmentStorage=true",
    "FUNCTIONS_WORKER_RUNTIME": "dotnet"
  },
  "Migration": {
    "JitAuthentication": {
      "UseKeyVault": false,
      "TestMode": true,
      "InlineRsaPrivateKey": "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC...\n-----END PRIVATE KEY-----",
      "TimeoutSeconds": 1.5,
      "CachePrivateKey": true
    },
    "B2C": {
      "TenantId": "your-b2c-tenant.onmicrosoft.com",
      "ClientId": "your-ropc-app-client-id",
      "ClientSecret": "your-client-secret",
      "PolicyName": "B2C_1_ROPC"
    },
    "ExternalId": {
      "TenantId": "your-external-id-tenant-id",
      "ClientId": "your-app-client-id",
      "ClientSecret": "your-client-secret",
      "ExtensionAppId": "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    }
  }
}
```

**Key Configuration Notes:**
- **UseKeyVault: false** → Uses inline RSA key for local development (set to true for production with Key Vault in v2.0)
- **TestMode: true** → Skips B2C validation (for testing without B2C access)
- **InlineRsaPrivateKey** → Paste entire private key content (including headers) for local development

---

**Step 3: Start Function Locally with ngrok**

Use the provided PowerShell script that handles both the function and ngrok tunnel:

```powershell
cd src\B2CMigrationKit.Function
.\start-local.ps1
```

**What the script does:**
- Builds the function
- Starts ngrok tunnel with static domain (or dynamic if not configured)
- Starts Azure Function on port 7071
- Copies the public endpoint URL to clipboard

**Expected Output:**
```
═══════════════════════════════════════════════
✅ ngrok Tunnel Active (Static Domain)
═══════════════════════════════════════════════

  Function URL: https://your-domain.ngrok-free.dev/api/JitAuthentication
  Static Domain: your-domain.ngrok-free.dev

✅ Function endpoint URL copied to clipboard!

Functions:
  JitAuthentication: [POST] http://localhost:7071/api/JitAuthentication
```

**Manual alternative** (without automation script):
```powershell
# Terminal 1: Start ngrok
ngrok http 7071

# Terminal 2: Start function
cd src\B2CMigrationKit.Function
func start
```

**✅ Success Indicators:**
- Function running on `http://localhost:7071`
- ngrok tunnel active with public HTTPS URL
- No errors about missing RSA key
- Logs show "Using inline RSA private key"

---

**Step 4: Configure Custom Authentication Extension**

**Prerequisites Checklist:**
- ✅ RSA keys generated (jit-private-key.pem, jit-public-key.jwk.json)
- ✅ Function local.settings.json configured with keys and credentials
- ✅ Users imported to External ID with RequiresMigration=true
- ✅ External ID tenant admin access
- ✅ Function running locally with ngrok tunnel active

**Sub-Step 1: Create Custom Extension App Registration**

1. **Go to Azure Portal → External ID Tenant**
2. **Navigate to:** App registrations → New registration
3. **Configuration:**
   - Name: `Custom Authentication Extension - JIT Migration`
   - Supported account types: `Accounts in this organizational directory only`
   - Redirect URI: Leave blank
   - Click **Register**

4. **Record the IDs:**
   ```
   Application (client) ID: ______________________
   Object ID: ______________________
   Directory (tenant) ID: ______________________
   ```

5. **Create Client Secret:**
   - Go to **Certificates & secrets**
   - **Client secrets** → **New client secret**
   - Description: `Custom Extension Secret`
   - Expires: 6 months (for testing)
   - Click **Add**
   - **COPY THE VALUE IMMEDIATELY**

---

**Sub-Step 2: Upload RSA Public Key**

⚠️ **IMPORTANT:** Azure Portal does NOT support uploading custom keys via UI. You MUST use Graph API.

```powershell
# Read the public key JWK
$publicKeyPath = "c:\code\B2C Migration\scripts\jit-public-key.jwk.json"
$publicKeyJwk = Get-Content $publicKeyPath -Raw | ConvertFrom-Json

# Custom Extension App details (from Sub-Step 1)
$tenantId = "your-tenant-id"
$customExtensionAppObjectId = "PASTE_OBJECT_ID_HERE"

# Get admin token
$token = (az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv)

# Prepare key credential
$keyCred = @{
    type = "AsymmetricX509Cert"
    usage = "Verify"
    key = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($publicKeyJwk | ConvertTo-Json -Compress))
    displayName = "JIT Migration RSA Public Key"
    customKeyIdentifier = [System.Text.Encoding]::UTF8.GetBytes($publicKeyJwk.kid)
}

# Upload to app registration
$body = @{
    keyCredentials = @($keyCred)
    tokenEncryptionKeyId = $publicKeyJwk.kid
} | ConvertTo-Json -Depth 10

Invoke-RestMethod -Method Patch `
    -Uri "https://graph.microsoft.com/beta/applications/$customExtensionAppObjectId" `
    -Headers @{
        Authorization = "Bearer $token"
        "Content-Type" = "application/json"
    } `
    -Body $body

Write-Host "✓ Public key uploaded successfully!" -ForegroundColor Green
```

---

**Sub-Step 3: Create Custom Authentication Extension Resource**

```powershell
$tenantId = "your-tenant-id"
$ngrokUrl = "https://abc123.ngrok.app"
$customExtensionAppClientId = "PASTE_CLIENT_ID_HERE"

$token = (az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv)

$extensionBody = @{
    "@odata.type" = "#microsoft.graph.onPasswordSubmitCustomExtension"
    displayName = "JIT Password Migration Extension - Local Testing"
    description = "Validates passwords against B2C and migrates users on first successful login"
    targetUrl = "$ngrokUrl/api/JitAuthentication"
    authenticationConfiguration = @{
        "@odata.type" = "#microsoft.graph.azureAdTokenAuthentication"
        resourceId = "api://$customExtensionAppClientId"
    }
} | ConvertTo-Json -Depth 10

$response = Invoke-RestMethod -Method Post `
    -Uri "https://graph.microsoft.com/beta/identity/customAuthenticationExtensions" `
    -Headers @{
        Authorization = "Bearer $token"
        "Content-Type" = "application/json"
    } `
    -Body $extensionBody

Write-Host "✓ Custom Extension created successfully!" -ForegroundColor Green
Write-Host "Extension ID: $($response.id)" -ForegroundColor Cyan

$extensionId = $response.id
$extensionId | Out-File "custom-extension-id.txt"
```

---

**Sub-Step 4: Create OnPasswordSubmit Listener Policy**

```powershell
$extensionAppId = "d7e9bb7927284f7c85d0fa045ec77b1f"  # Without dashes
$extensionId = Get-Content "custom-extension-id.txt"

# Apply to ALL applications (easier for testing)
$conditions = @{
    applications = @{
        includeAllApplications = $true
    }
}

$token = (az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv)

$listenerBody = @{
    "@odata.type" = "#microsoft.graph.onPasswordSubmitListener"
    priority = 500
    conditions = $conditions
    handler = @{
        "@odata.type" = "#microsoft.graph.onPasswordMigrationCustomExtensionHandler"
        migrationPropertyId = "extension_${extensionAppId}_RequiresMigration"
        customExtension = @{
            id = $extensionId
        }
    }
} | ConvertTo-Json -Depth 10

$response = Invoke-RestMethod -Method Post `
    -Uri "https://graph.microsoft.com/beta/identity/authenticationEventListeners" `
    -Headers @{
        Authorization = "Bearer $token"
        "Content-Type" = "application/json"
    } `
    -Body $listenerBody

Write-Host "✓ Authentication Event Listener created successfully!" -ForegroundColor Green
```

**Verification Checklist:**
- [ ] Custom Extension app registered
- [ ] RSA public key uploaded
- [ ] Azure Function running locally
- [ ] ngrok tunnel active
- [ ] Custom Extension resource created
- [ ] Authentication Event Listener created
- [ ] Test user exists with RequiresMigration=true

---

**Step 4: Import Test User**

Run the import to create users with random passwords:

```powershell
.\scripts\Start-LocalImport.ps1 -Verbose
```

**Verify in External ID:**
- User exists: `user@domain.com`
- `extension_<appId>_RequiresMigration == true`
- Password is NOT the real B2C password

---

**Step 5: Test JIT Flow**

**Test with HTTP Client:**

Create `test-jit.http`:
```http
POST https://abc123.ngrok.app/api/JitAuthentication
Content-Type: application/json

{
  "type": "customAuthenticationExtension",
  "data": {
    "authenticationContext": {
      "correlationId": "test-12345",
      "user": {
        "id": "user-object-id-from-external-id",
        "userPrincipalName": "testuser@yourdomain.com"
      }
    },
    "passwordContext": {
      "userPassword": "RealB2CPassword123!",
      "nonce": "test-nonce-value"
    }
  }
}

There is a utility script to test this in the \scripts directory:

.\Test-JIT-Function.ps1

```

**Expected Response (TestMode=true):**
```json
{
  "data": {
    "actions": [
      {
        "@odata.type": "microsoft.graph.customAuthenticationExtension.migratePassword"
      }
    ]
  }
}
```

---

#### VS Code Debugging Setup

1. **Create `.vscode/launch.json`:**

```json
{
  "version": "0.2.0",
  "configurations": [
    {
      "name": "Attach to .NET Functions",
      "type": "coreclr",
      "request": "attach",
      "processId": "${command:pickProcess}"
    }
  ]
}
```

2. **Start Function with Script:**
```powershell
cd src\\B2CMigrationKit.Function
.\\start-local.ps1
```

3. **Attach Debugger:**
   - Open `JitAuthenticationFunction.cs` or `JitMigrationService.cs`
   - Set breakpoints (F9)
   - Press F5 → Select "Attach to .NET Functions"
   - Find and select the `func` or `dotnet` process

4. **Recommended Breakpoints:**
   - `JitAuthenticationFunction.cs:60` - Parse External ID payload
   - `JitAuthenticationFunction.cs:123` - Call JitMigrationService
   - `JitMigrationService.cs:73` - Get user and check migration status
   - `JitMigrationService.cs:125` - Validate credentials against B2C via ROPC
   - `JitMigrationService.cs:156` - Validate password complexity
   - `JitMigrationService.cs:193` - Update user extension attributes

---

#### ngrok Web Interface

Access the ngrok web interface for request inspection:

```
http://localhost:4040
```

**Features:**
- View all HTTP requests to your function
- Inspect request/response headers and body
- **Replay requests** - Reproduce errors without redoing login flow
- Filter by path (`/api/JitAuthentication`) or status code

---

#### Understanding the Request Flow

**External ID Custom Authentication Extension Flow:**

```
1. User logs into External ID
   ↓
2. External ID validates user exists
   ↓
3. External ID calls JIT Function with payload:
   {
     "data": {
       "authenticationContext": {
         "user": {
           "id": "user-object-id",
           "userPrincipalName": "user@tenant.com"
         },
         "correlationId": "correlation-id"
       },
       "passwordContext": {
         "userPassword": "user-entered-password"
       }
     }
   }
   ↓
4. JIT Function validates and returns action:
   {
     "data": {
       "@odata.type": "microsoft.graph.onPasswordSubmitResponseData",
       "actions": [{
         "@odata.type": "microsoft.graph.passwordsubmit.MigratePassword"
       }]
     }
   }
   ↓
5. External ID updates password and completes login
```

---

#### Log Patterns

**Successful Migration:**
```
[JIT Function] HTTP POST received | RequestId: req-abc123
[JIT Function] Parsed External ID payload | UserId: user-obj-id | UPN: testuser@...
[JIT Migration] Starting | UserId: user-obj-id | CorrelationId: corr-xyz
[JIT Migration] Step 1/3: Checking migration status
[JIT Migration] ✓ User needs migration - Proceeding
[JIT Migration] Step 2/3: Validating credentials against B2C via ROPC
[JIT Migration] ✓ B2C credentials validated successfully
[JIT Migration] Step 3/3: Validating password complexity
[JIT Migration] ✓ Password complexity validated
[JIT Migration] ✅ SUCCESS - Returning MigratePassword action | Duration: 1250ms
```

**Already Migrated (Fast Path):**
```
[JIT Migration] Step 1/3: Checking migration status
[JIT Migration] ✓ User already migrated - Allowing login | Duration: 450ms
```

**Invalid Credentials:**
```
[JIT Migration] Step 2/3: Validating credentials against B2C via ROPC
[JIT Migration] ❌ FAILED - B2C credential validation failed
```

---

#### Production Deployment

> **⚠️ IMPORTANT**: Production deployment with secure certificate management and automated infrastructure provisioning will be **fully implemented and validated in v2.0**. 
>
> **Current Release (v1.0)**:
> - ✅ Local development with self-signed certificates and inline secrets (gitignored configuration files)
> - ✅ Development testing and validation with ngrok
>
> **Future Release (v2.0)**:
> - 🔜 Secure certificate management automation
> - 🔜 Managed Identity for Azure Function
> - 🔜 Production Azure Function deployment templates
> - 🔜 Automated infrastructure deployment aligned with SFI

---

#### JIT Troubleshooting

**Issue: JIT Not Triggering**

**Symptom:** User enters correct B2C password but no JIT call happens

**Solutions:**
```powershell
# Verify user has random password (not real B2C password)
Get-MgUser -UserId "user@domain.com" | Select-Object PasswordProfile

# Check RequiresMigration status
Get-MgUser -UserId "user@domain.com" -Property "extension_*" | 
    Select-Object -ExpandProperty AdditionalProperties

# Verify custom extension is assigned
Get-MgIdentityAuthenticationEventsFlow
```

---

**Issue: ngrok URL Changes on Restart**

**Solutions:**

Quick update with automation:
```powershell
.\scripts\Setup-JitCustomExtension.ps1 `
    -TenantId "your-tenant-id" `
    -NgrokUrl "https://NEW-URL.ngrok.app" `
    -PublicKeyPath ".\keys\public_key.pem" `
    -ExtensionAppId "existing-app-id"
```

Or use ngrok paid plan for static domain:
```powershell
ngrok http 7071 --domain=myapp.ngrok.app
```

---

**Issue: Function Timeout (2 seconds)**

**Optimize configuration:**
```json
{
  "Migration": {
    "JitAuthentication": {
      "TimeoutSeconds": 1.5,
      "CachePrivateKey": true
    },
    "Retry": {
      "MaxRetries": 1,
      "DelaySeconds": 0.1
    }
  }
}
```

**Monitor performance:**
```kusto
requests
| where name == "JitAuthentication"
| summarize avg(duration), max(duration), percentile(duration, 95)
```

**Target: < 1500ms for 95th percentile**

---

**Issue: Test Mode Enabled in Production**

⚠️ **Security Warning:** TestMode=true in production:
- Skips B2C credential validation (ANY password accepted)
- Skips password complexity checks
- Allows unauthorized access
- **NEVER use in production**

**Solution:**
```powershell
az functionapp config appsettings set `
    --name my-function `
    --resource-group my-rg `
    --settings "Migration__JitAuthentication__TestMode=false"
```

---

#### JIT Configuration Reference

**Local Development:**
```json
{
  "Migration": {
    "JitAuthentication": {
      "UseKeyVault": false,
      "TestMode": true,
      "InlineRsaPrivateKey": "-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----",
      "TimeoutSeconds": 1.5,
      "CachePrivateKey": true
    }
  }
}

You cannot paste the private key as it is not JSON compliant. You need to convert the key
to a string delimited by "\n".

There is a utility in the \scripts directory to do this:

.\FormatPemWithSlashN
```

> **Note**: Production configuration will be documented in v2.0 with automated deployment templates.

#### Common JIT Debugging Scenarios

**Scenario: User Not Found**
- Check userId in payload: `[JIT Function] Parsed External ID payload | UserId: ...`
- Verify user exists: `az ad user show --id "<userId>"`
- Check app registration permissions

**Scenario: B2C Credential Validation Failed**
- Verify ROPC policy exists: `B2C_1_ROPC`
- Test B2C login directly:
  ```bash
  curl -X POST https://b2cprod.b2clogin.com/b2cprod.onmicrosoft.com/B2C_1_ROPC/oauth2/v2.0/token \
    -d "grant_type=password" \
    -d "username=test@b2cprod.onmicrosoft.com" \
    -d "password=Test123!@#" \
    -d "client_id=<client-id>" \
    -d "scope=openid"
  ```
- Check UPN transformation between External ID and B2C

**Scenario: Password Complexity Failed**
- Check password policy in `local.settings.json`
- Verify password has: 8+ chars, uppercase, lowercase, digit, special char
- Set breakpoint at `JitMigrationService.cs:156`
- User must reset password via SSPR

**Scenario: Graph API Throttling (HTTP 429)**
- Graph API limit: ~60 ops/sec per app registration
- View retry logs: `[GraphClient] Request throttled (429/503) - Retrying in X ms...`
- For load testing, add delays between requests

#### JIT Debugging Tips

- **Use ngrok replay** to reproduce errors quickly
- **Filter logs by CorrelationId** to trace end-to-end operations
- **Use conditional breakpoints**: Right-click breakpoint → `userPrincipalName.Contains("testuser")`
- **Monitor ngrok web UI** (localhost:4040) for all requests in real-time
- **Rebuild after code changes**: `dotnet build src/B2CMigrationKit.Function`

---

## Attribute Mapping Configuration

### Overview

Both Azure AD B2C and Entra External ID use the same Microsoft Graph User object model. Most attributes can be copied directly without mapping. However, you may need to:

1. **Map custom extension attributes** with different names between tenants
2. **Exclude certain fields** from being copied
3. **Configure migration-specific attributes** (B2CObjectId, RequiresMigration)

### Configuration Structure

#### Export Configuration

Controls which fields are exported from B2C:

```json
{
  "Migration": {
    "Export": {
      "SelectFields": "id,userPrincipalName,displayName,givenName,surname,mail,mobilePhone,identities,extension_abc123_CustomerId"
    }
  }
}
```

**Default fields:**
- `id` - User's ObjectId (required)
- `userPrincipalName` - UPN
- `displayName` - Display name
- `givenName` - First name
- `surname` - Last name
- `mail` - Email address
- `mobilePhone` - Mobile phone
- `identities` - All user identities

**To add custom extension attributes:**
Add them to the comma-separated list in `SelectFields`. For example:
```
"SelectFields": "id,userPrincipalName,displayName,...,extension_abc123_CustomerId,extension_abc123_Department"
```

#### Import Configuration

Controls how attributes are imported into External ID:

```json
{
  "Migration": {
    "Import": {
      "AttributeMappings": {
        "extension_abc123_LegacyId": "extension_xyz789_CustomerId"
      },
      "ExcludeFields": ["createdDateTime"],
      "MigrationAttributes": {
        "StoreB2CObjectId": true,
        "B2CObjectIdTarget": "extension_xyz789_OriginalB2CId",
        "SetRequiresMigration": true,
        "RequiresMigrationTarget": "extension_xyz789_RequiresMigration"
      }
    }
  }
}
```

##### AttributeMappings

Maps source attribute names to different target names.

**Key** = source attribute name in B2C
**Value** = target attribute name in External ID

Example:
```json
"AttributeMappings": {
  "extension_b2c_app_LegacyCustomerId": "extension_extid_app_CustomerId",
  "extension_b2c_app_Department": "extension_extid_app_DepartmentCode"
}
```

**Behavior:**
- If attribute is in mappings: rename it to target name
- If attribute is NOT in mappings: copy as-is (same name)
- All attributes not explicitly mapped or excluded are copied unchanged

##### ExcludeFields

List of field names to exclude from import. These fields will not be copied to External ID.

```json
"ExcludeFields": [
  "createdDateTime",
  "lastPasswordChangeDateTime",
  "extension_abc123_TemporaryField"
]
```

##### MigrationAttributes

Controls migration-specific attributes:

**StoreB2CObjectId** (bool, default: `true`)
- Whether to store the original B2C ObjectId in External ID
- Useful for correlation and troubleshooting
- Set to `false` if you don't need this tracking

**B2CObjectIdTarget** (string, optional)
- Target attribute name for storing B2C ObjectId
- Default: `extension_{ExtensionAppId}_B2CObjectId`
- Only used if `StoreB2CObjectId` is `true`

**SetRequiresMigration** (bool, default: `true`)
- Whether to set the RequiresMigration flag
- Used by JIT authentication to know if password needs migration
- The value is set to `true` by default (password NOT yet migrated)
- Set to `false` if using a different migration tracking mechanism

**RequiresMigrationTarget** (string, optional)
- Target attribute name for the RequiresMigration flag
- Default: `extension_{ExtensionAppId}_RequiresMigration`
- Only used if `SetRequiresMigration` is `true`

### Common Mapping Scenarios

#### Scenario 1: Simple Migration (No Custom Attributes)

Use default configuration - no mapping needed:

```json
{
  "Export": {
    "SelectFields": "id,userPrincipalName,displayName,givenName,surname,mail,mobilePhone,identities"
  },
  "Import": {
    "AttributeMappings": {},
    "ExcludeFields": [],
    "MigrationAttributes": {
      "StoreB2CObjectId": true,
      "SetRequiresMigration": true
    }
  }
}
```

#### Scenario 2: Different Extension Attribute Names

If attribute names differ between B2C and External ID:

```json
{
  "Export": {
    "SelectFields": "id,userPrincipalName,...,extension_b2c_CustomerId"
  },
  "Import": {
    "AttributeMappings": {
      "extension_b2c_CustomerId": "extension_extid_LegacyUserId"
    }
  }
}
```

The `extension_b2c_CustomerId` will be renamed to `extension_extid_LegacyUserId` during import.

#### Scenario 3: Complex Mapping with Multiple Custom Attributes

```json
{
  "Export": {
    "SelectFields": "id,userPrincipalName,displayName,givenName,surname,mail,mobilePhone,identities,extension_abc_CustomerId,extension_abc_Department,extension_abc_EmployeeType,extension_abc_CostCenter"
  },
  "Import": {
    "AttributeMappings": {
      "extension_abc_CustomerId": "extension_xyz_LegacyId",
      "extension_abc_Department": "extension_xyz_DeptCode",
      "extension_abc_EmployeeType": "extension_xyz_UserType"
    },
    "ExcludeFields": [
      "extension_abc_CostCenter"
    ],
    "MigrationAttributes": {
      "StoreB2CObjectId": true,
      "B2CObjectIdTarget": "extension_xyz_B2COriginalId",
      "SetRequiresMigration": true,
      "RequiresMigrationTarget": "extension_xyz_RequiresMigration"
    }
  }
}
```

This configuration:
- Exports 4 custom extension attributes
- Maps 3 of them to different names
- Excludes `CostCenter` from import
- Stores B2C ObjectId as `extension_xyz_B2COriginalId`
- Sets migration flag as `extension_xyz_Migrated`

### Important Notes for Attribute Mapping

#### 1. Create Extension Attributes First

Before importing, ensure all target custom attributes exist in your External ID tenant:

1. Go to **Azure Portal** → **External Identities** → **Custom user attributes**
2. Create each custom attribute you plan to use
3. Note the full attribute name: `extension_{appId}_{attributeName}`

#### 2. Extension App ID

The `ExtensionAppId` (without dashes) is used to construct full attribute names:

```json
{
  "ExternalId": {
    "ExtensionAppId": "abc123def456..."  // No dashes!
  }
}
```

Full attribute name format: `extension_{ExtensionAppId}_{attributeName}`

#### 3. Standard User Object Fields

Standard Graph API User fields are copied automatically (if included in export):
- displayName, givenName, surname
- mail, mobilePhone, otherMails
- streetAddress, city, state, postalCode, country
- userPrincipalName, identities
- accountEnabled

These do NOT need mapping unless you're using a non-standard scenario.

#### 4. Automatic Transformations

The import process automatically handles:
- **UPN domain update**: Changes `user@b2c.onmicrosoft.com` to `user@externalid.onmicrosoft.com`
- **Identity issuer update**: Updates identity issuer from B2C domain to External ID domain
- **Password replacement**: Sets random placeholder password for JIT migration

### UPN and Email Identity Transformation

**Background**: Entra External ID enforces stricter validation than Azure AD B2C:
- UPNs must belong to the External ID tenant domain
- All users must have an `emailAddress` identity (required for OTP and password reset)
- B2C allows users without email addresses; External ID does not

**Automatic Transformation Logic**:

The import orchestrator automatically applies these transformations:

#### 1. UPN Domain Transformation

**Code Location**: `ImportOrchestrator.cs:TransformUpnForExternalId()`

**Purpose**: Changes the UPN domain from B2C to External ID while **preserving the local part identifier** to enable JIT authentication. This approach serves as a workaround to enable the use of the [sign-in alias](https://learn.microsoft.com/en-us/entra/external-id/customers/how-to-sign-in-alias) feature **during** JIT password migration in Entra External ID.

**Note**: This implementation differs from the official Microsoft documentation approach, which creates entirely new UPNs. By preserving the local part of the UPN, we maintain user identifier continuity across both tenants, enabling seamless JIT authentication and supporting sign-in alias scenarios during the migration process.

```csharp
// Original B2C UPN
user.UserPrincipalName = "user#EXT#@b2cprod.onmicrosoft.com"

// Transformation steps:
// 1. Extract local part (before @): "user#EXT#"
// 2. Remove #EXT# markers: "user"
// 3. Remove underscores and dots from local part: "user" (unchanged in this case)
// 4. Replace domain with External ID tenant domain
// 5. If local part is empty after cleaning, generate GUID-based identifier

// Result
user.UserPrincipalName = "user@externalid.onmicrosoft.com"
// OR (if local part becomes empty after cleaning)
user.UserPrincipalName = "28687c60@externalid.onmicrosoft.com"
```

**Why Preserve the Local Part?**

The local part (identifier before @) is preserved because the **JIT Function reverses this transformation** during authentication:

```csharp
// JIT Function: TransformUpnForB2C() - Located in JitAuthenticationFunction.cs

// 1. External ID provides UPN during login
string externalIdUpn = "user@externalid.onmicrosoft.com";

// 2. JIT extracts local part
string localPart = "user";  // Everything before @

// 3. Reconstructs B2C UPN with B2C domain
string b2cUpn = "user@b2cprod.onmicrosoft.com";

// 4. Validates credentials against B2C ROPC using this B2C UPN
```

**Key Points**:
- ✅ **Local part preserved**: Acts as unique identifier across both tenants
- ✅ **Only domain changes**: From B2C domain to External ID domain (import) and vice versa (JIT)
- ✅ **Bidirectional mapping**: Import transforms B2C→External ID, JIT transforms External ID→B2C
- ⚠️ **Critical for JIT**: If local part is not preserved, JIT cannot map users back to B2C

**Configuration**: The target domain is taken from `Migration.ExternalId.TenantDomain` in appsettings.json.

#### 2. Authentication Method Handling (Email Identity)

**Code Location**: `ImportOrchestrator.cs:EnsureEmailIdentity()`

**Important**: External ID requires all users to have an email identity for authentication (Email+Password or Email OTP). The import logic ensures every user gets an email identity.

```csharp
// Decision tree:
// 1. Check if user already has emailAddress identity -> use it (no changes)
// 2. If user has 'mail' field -> create email identity from mail
// 3. If user has NO 'mail' -> fallback to userPrincipalName as email (for users with only userName + userPrincipalName)

// Example results:

// Scenario 1: User has mail field
// B2C User:
{
  "mail": "john.doe@example.com",
  "identities": [
    { "signInType": "userName", "issuerAssignedId": "johndoe" },
    { "signInType": "userPrincipalName", "issuerAssignedId": "guid@b2c.onmicrosoft.com" }
  ]
}
// External ID Result (Email+Password with JIT):
{
  "mail": "john.doe@example.com",
  "identities": [
    { "signInType": "userName", "issuerAssignedId": "johndoe", "issuer": "eeid.onmicrosoft.com" },
    { "signInType": "emailAddress", "issuerAssignedId": "john.doe@example.com", "issuer": "eeid.onmicrosoft.com" },
    { "signInType": "userPrincipalName", "issuerAssignedId": "guid@eeid.onmicrosoft.com", "issuer": "eeid.onmicrosoft.com" }
  ]
}

// Scenario 2: User has NO mail field (only userName + userPrincipalName)
// B2C User:
{
  "mail": null,
  "identities": [
    { "signInType": "userName", "issuerAssignedId": "loadtest5017" },
    { "signInType": "userPrincipalName", "issuerAssignedId": "a3f2d8e1@b2c.onmicrosoft.com" }
  ]
}
// External ID Result (uses userPrincipalName as email fallback):
{
  "mail": null,
  "identities": [
    { "signInType": "userName", "issuerAssignedId": "loadtest5017", "issuer": "eeid.onmicrosoft.com" },
    { "signInType": "emailAddress", "issuerAssignedId": "a3f2d8e1@eeid.onmicrosoft.com", "issuer": "eeid.onmicrosoft.com" },
    { "signInType": "userPrincipalName", "issuerAssignedId": "a3f2d8e1@eeid.onmicrosoft.com", "issuer": "eeid.onmicrosoft.com" }
  ]
}
// Warning logged: "User X has no email in 'mail' field. Using userPrincipalName as email fallback."

// Scenario 3: User already has emailAddress identity from B2C (preserved)
// B2C User:
{
  "mail": "jane@example.com",
  "identities": [
    { "signInType": "emailAddress", "issuerAssignedId": "jane@example.com" },
    { "signInType": "userPrincipalName", "issuerAssignedId": "guid@b2c.onmicrosoft.com" }
  ]
}
// External ID Result (emailAddress preserved, no duplicate created):
{
  "mail": "jane@example.com",
  "identities": [
    { "signInType": "emailAddress", "issuerAssignedId": "jane@example.com", "issuer": "eeid.onmicrosoft.com" },
    { "signInType": "userPrincipalName", "issuerAssignedId": "guid@eeid.onmicrosoft.com", "issuer": "eeid.onmicrosoft.com" }
  ]
}
```

**Email OTP (Passwordless) Configuration**:

Set `Migration.Import.MigrationAttributes.UseEmailOtp = true` to use Email OTP instead of Email+Password:

```json
{
  "Migration": {
    "Import": {
      "MigrationAttributes": {
        "UseEmailOtp": true  // Creates federated identity (issuer="mail") instead of emailAddress
      }
    }
  }
}
```

When `UseEmailOtp = true`:
- Creates `signInType = "federated"` with `issuer = "mail"` (Email OTP / passwordless)
- Users login with OTP sent to email (no password migration needed)
- JIT password migration is NOT used (no password to migrate)

When `UseEmailOtp = false` (default):
- Creates `signInType = "emailAddress"` (Email+Password)
- Users login with email and password
- JIT password migration validates password on first login

**Identity Preservation Rules**:

The import orchestrator preserves all B2C identity types:

1. ✅ **userName** identities are PRESERVED (not converted)
   - Original userName from B2C is maintained
   - Only issuer domain is updated to External ID domain
   - Users can login with their original userName

2. ✅ **userPrincipalName** identities are PRESERVED (not converted)
   - Original userPrincipalName structure is maintained
   - Only domain is updated via `TransformUpnForExternalId()`
   - GUID-based usernames stay as userPrincipalName (not converted to userName)

3. ✅ **emailAddress** identities are ADDED if missing
   - If user has 'mail' field → uses that email
   - If user has NO 'mail' → uses userPrincipalName as email
   - Existing emailAddress identities are preserved (no duplicates)


#### 3. Identity Issuer Update

All existing identity issuers are updated from B2C domain to External ID domain:

```csharp
// Before
identity.Issuer = "b2cprod.onmicrosoft.com"

// After
identity.Issuer = "externalid.onmicrosoft.com"
```

### Impact on Attribute Mapping

**UPN and Authentication Methods** are NOT subject to attribute mapping configuration:
- UPN transformation happens automatically regardless of `AttributeMappings`
- Email identity creation logic cannot be disabled
- SMS (mobilePhone) is automatically migrated if present
- Standard identity transformations cannot be disabled

**Standard User Fields** are migrated automatically (no mapping needed):
- `mobilePhone` - **Critical for SMS-based SSPR**
- `mail` - Used for email identity if present
- `displayName`, `givenName`, `surname`
- `streetAddress`, `city`, `state`, `postalCode`, `country`
- `userPrincipalName`, `identities`, `accountEnabled`

**Custom Extension Attributes** ARE subject to mapping:
- Use `AttributeMappings` to rename extension attributes
- Use `ExcludeFields` to prevent copying specific attributes

### Debugging UPN/Email/SMS Transformations

Enable verbose logging to see transformation details:

```json
{
  "Migration": {
    "VerboseLogging": true
  }
}
```

## Import Audit Logs

### Overview

The import process automatically creates detailed audit logs in Azure Blob Storage. These logs provide evidence of each user migration, including success/failure status, timestamps, and user details.

### Benefits

- **Compliance**: Permanent record of all migration activities
- **Auditing**: Track exactly which users were migrated and when
- **Troubleshooting**: Identify failed imports with error details
- **Reporting**: Generate migration reports and statistics

### Audit Log Structure

Each batch import creates a separate audit log file in JSON format:

#### Filename Format
```
import-audit_{sourceFile}_batch{number}_{timestamp}.json
```

Example:
```
import-audit_000042_batch000_20250111183045.json
```

#### JSON Structure

```json
{
  "Timestamp": "2025-01-11T18:30:45.123Z",
  "SourceBlobName": "users_000042.json",
  "BatchNumber": 0,
  "TotalUsers": 100,
  "SuccessCount": 100,
  "FailureCount": 0,
  "DurationMs": 1234.56,
  "SuccessfulUsers": [
    {
      "B2CObjectId": "12345678-1234-1234-1234-123456789012",
      "ExternalIdObjectId": "87654321-4321-4321-4321-210987654321",
      "UserPrincipalName": "user@externalid.onmicrosoft.com",
      "DisplayName": "John Doe",
      "ImportedAt": "2025-01-11T18:30:45.789Z"
    },
    ...
  ],
  "FailedUsers": [
    {
      "B2CObjectId": "99999999-9999-9999-9999-999999999999",
      "UserPrincipalName": "failed.user@example.com",
      "ErrorMessage": "User already exists",
      "ErrorCode": "Request_ResourceExists",
      "FailedAt": "2025-01-11T18:30:46.123Z"
    },
    ...
  ]
}
```

### Configuration

#### Storage Container

Audit logs are stored in a dedicated blob container:

**Default**: `import-audit`

Configure in `appsettings.json`:

```json
{
  "Migration": {
    "Storage": {
      "ImportAuditContainerName": "import-audit"
    }
  }
}
```

#### Auto-Creation

The import process automatically:
1. Creates the `import-audit` container if it doesn't exist
2. Generates one audit log per batch processed
3. Continues import even if audit log save fails (logs warning)

### Viewing Audit Logs

#### Azure Portal

1. Go to your Storage Account
2. Navigate to **Containers**
3. Open the `import-audit` container
4. Download any audit log file to view

#### Azure Storage Explorer

1. Connect to your storage account
2. Expand **Blob Containers**
3. Open `import-audit`
4. Browse and download audit logs

#### Command Line (Azure CLI)

List all audit logs:
```bash
az storage blob list \
  --account-name <storage-account> \
  --container-name import-audit \
  --output table
```

Download a specific audit log:
```bash
az storage blob download \
  --account-name <storage-account> \
  --container-name import-audit \
  --name import-audit_000042_batch000_20250111183045.json \
  --file audit.json
```

#### Local Development (Azurite)

Use Azure Storage Explorer or any blob storage tool to connect to:
- **Connection String**: `UseDevelopmentStorage=true`
- **Container**: `import-audit`

### Audit Log Analysis

#### Count Total Migrations

```bash
# Download all audit logs and count total successful imports
jq -r '.SuccessCount' *.json | awk '{sum+=$1} END {print sum}'
```

#### Find Failed Imports

```bash
# List all failed user imports
jq -r '.FailedUsers[] | "\(.UserPrincipalName): \(.ErrorMessage)"' *.json
```

#### Calculate Success Rate

```bash
# Calculate overall success rate
jq -r '[.TotalUsers, .SuccessCount, .FailureCount] | @csv' *.json
```

#### Extract All Migrated Users

```bash
# Get list of all successfully migrated B2C ObjectIds
jq -r '.SuccessfulUsers[].B2CObjectId' *.json > migrated-users.txt
```

### Retention and Cleanup

#### Recommended Practices

1. **Keep logs for compliance period**: Typically 1-7 years depending on regulations
2. **Archive old logs**: Move to Cool/Archive tier after 90 days
3. **Backup critical logs**: Copy to separate storage for disaster recovery

#### Storage Lifecycle Management

Create a lifecycle policy to automatically archive old audit logs:

```json
{
  "rules": [
    {
      "enabled": true,
      "name": "ArchiveImportAudits",
      "type": "Lifecycle",
      "definition": {
        "actions": {
          "baseBlob": {
            "tierToCool": {
              "daysAfterModificationGreaterThan": 90
            },
            "tierToArchive": {
              "daysAfterModificationGreaterThan": 365
            }
          }
        },
        "filters": {
          "blobTypes": ["blockBlob"],
          "prefixMatch": ["import-audit/"]
        }
      }
    }
  ]
}
```

### Troubleshooting Audit Logs

#### Audit Logs Not Created

**Issue**: No files in `import-audit` container

**Solutions**:
1. Check container exists (auto-created but verify permissions)
2. Enable verbose logging to see audit save operations
3. Check logs for warnings about audit save failures
4. Verify storage account has write permissions

#### Large Audit Files

**Issue**: Audit files are very large

**Explanation**: Each batch can contain 100+ users. For large migrations:
- 100 users/batch × 100 fields/user = large JSON files
- This is expected and normal

**Optimization**:
- Consider compression (gzip) for long-term storage
- Use blob storage tiering for cost efficiency

#### Missing Failed User Details

**Issue**: `FailedUsers` array is empty even with failures

**Explanation**: Current implementation tracks batch-level failures. Individual user failures within a batch require enhancement to the Graph API batch client.

**Workaround**: Check console logs for detailed error messages during import.

### Security Considerations for Audit Logs

#### Sensitive Data

Audit logs contain:
- ✅ User Principal Names (UPNs)
- ✅ Display Names
- ✅ ObjectIds
- ❌ Passwords (never logged)
- ❌ Extension attribute values (not included)

#### Access Control

Restrict access to audit logs:
1. **RBAC**: Assign `Storage Blob Data Reader` role only to authorized personnel
2. **Private Endpoints**: Use private endpoints for storage account
3. **SAS Tokens**: Generate time-limited SAS tokens for temporary access
4. **Encryption**: Enable encryption at rest (default in Azure)


### Example: Generate Migration Report

PowerShell script to generate a summary report:

```powershell
# Download all audit logs
$auditLogs = Get-AzStorageBlob -Container "import-audit" -Context $ctx |
    Get-AzStorageBlobContent -Force

# Parse and summarize
$summary = $auditLogs | ForEach-Object {
    $content = Get-Content $_.Name | ConvertFrom-Json
    [PSCustomObject]@{
        Timestamp = $content.Timestamp
        SourceFile = $content.SourceBlobName
        Success = $content.SuccessCount
        Failed = $content.FailureCount
        Duration = $content.DurationMs
    }
}

# Display report
$summary | Format-Table -AutoSize
$summary | Export-Csv -Path "migration-report.csv" -NoTypeInformation

# Calculate totals
$totalSuccess = ($summary | Measure-Object -Property Success -Sum).Sum
$totalFailed = ($summary | Measure-Object -Property Failed -Sum).Sum
$avgDuration = ($summary | Measure-Object -Property Duration -Average).Average

Write-Host "`nMigration Summary"
Write-Host "================="
Write-Host "Total Successful: $totalSuccess"
Write-Host "Total Failed: $totalFailed"
Write-Host "Success Rate: $([math]::Round($totalSuccess/($totalSuccess+$totalFailed)*100, 2))%"
Write-Host "Avg Batch Duration: $([math]::Round($avgDuration, 2)) ms"
```

## Deployment Guide

### Infrastructure Deployment

1. **Deploy Azure Resources**
   ```bash
   # Deploy via Azure Portal or Bicep
   az deployment group create \
     --resource-group rg-b2c-migration \
     --template-file infra/main.bicep
   ```

2. **Configure Private Endpoints** (planned for v2.0)
   - Storage Account
   - (Optional) Function App

3. **Set Up Managed Identity**
   ```bash
   # Enable system-assigned identity on Function
   az functionapp identity assign \
     --name func-b2c-migration \
     --resource-group rg-b2c-migration

   # Grant permissions
   az role assignment create \
     --assignee <managed-identity-id> \
     --role "Storage Blob Data Contributor" \
     --scope <storage-account-resource-id>
   ```

### Function Deployment

```bash
cd src/B2CMigrationKit.Function

# Publish locally
dotnet publish -c Release

# Deploy to Azure
func azure functionapp publish func-b2c-migration

# Restart function (critical!)
az functionapp restart \
  --name func-b2c-migration \
  --resource-group rg-b2c-migration
```

**Important**: Always restart the Function App after deployment to load new binaries.

### Configuration Deployment

```bash
# Set application settings
az functionapp config appsettings set \
  --name func-b2c-migration \
  --resource-group rg-b2c-migration \
  --settings \
    "Migration__B2C__TenantId=your-tenant-id" \
    "Migration__ExternalId__TenantId=your-tenant-id"
```

## Operations & Monitoring

### Application Insights Dashboards

**Migration Progress Dashboard**
```kql
let startTime = ago(24h);
traces
| where timestamp > startTime
| where message contains "RUN SUMMARY"
| extend Operation = extract("([A-Z][a-z]+ [A-Z][a-z]+)", 1, message)
| extend TotalItems = toint(extract("Total: ([0-9]+)", 1, message))
| extend SuccessCount = toint(extract("Success: ([0-9]+)", 1, message))
| extend FailureCount = toint(extract("Failed: ([0-9]+)", 1, message))
| project timestamp, Operation, TotalItems, SuccessCount, FailureCount
```

**JIT Migration Tracking**
```kql
customMetrics
| where name == "JIT.MigrationsCompleted"
| summarize MigrationsCompleted = sum(value) by bin(timestamp, 1h)
| render timechart
```

**Throttling Analysis**
```kql
traces
| where message contains "throttle" or message contains "429"
| summarize ThrottleCount = count() by bin(timestamp, 5m), severity = severityLevel
| render timechart
```

### Alerts Configuration

**Recommended Alerts:**

1. **High Failure Rate**
   ```kql
   traces
   | where message contains "failed" or severityLevel >= 3
   | summarize FailureCount = count() by bin(timestamp, 5m)
   | where FailureCount > 10
   ```

2. **Excessive Throttling**
   ```kql
   traces
   | where message contains "429"
   | summarize ThrottleCount = count() by bin(timestamp, 5m)
   | where ThrottleCount > 50
   ```

3. **JIT Authentication Failures**
   ```kql
   customMetrics
   | where name == "JIT.CredentialValidationFailed"
   | summarize Failures = sum(value) by bin(timestamp, 5m)
   | where Failures > 20
   ```

### Performance Tuning

**Throughput Optimization:**

1. **Scale Horizontally with Multiple Instances**
   - Deploy multiple containers/VMs with different IPs
   - Each instance uses a dedicated app registration
   - Avoids IP-based throttling limits (~60 ops/sec per IP)

2. **Adjust Batch Size**
   - Larger batches = fewer API calls
   - Smaller batches = better error isolation
   - Recommended: 50-100 users per batch

3. **Add Delays**
   - Use `BatchDelayMs` to space out operations
   - Reduces burst throttling
   - Increases overall runtime but improves reliability

### Scaling Patterns

Understanding how to scale the migration toolkit is critical for achieving maximum throughput while respecting Microsoft Graph API rate limits.

#### Graph API Throttling Fundamentals

Microsoft Graph API throttling works on **two dimensions**:

1. **Per App Registration (Client ID)** - ~60 operations/second per app
2. **Per IP Address** - Cumulative limit across all apps from that IP

This means:
- ✅ Single instance (1 IP) with 1 app = ~60 ops/sec
- ❌ Single instance (1 IP) with 3 apps ≠ 180 ops/sec (still limited by IP)
- ✅ 3 instances (3 different IPs) with 1 app each = ~180 ops/sec

**Key Principle**: Each instance (Console App or Azure Function) uses **1 app registration**. To scale, deploy **multiple instances** on **different IP addresses**.

#### Console App Scaling

**Single Instance (Default)**

```json
{
  "Migration": {
    "B2C": {
      "AppRegistration": {
        "ClientId": "app-1",
        "ClientSecretName": "Secret1",
        "Enabled": true
      }
    },
    "ExternalId": {
      "AppRegistration": {
        "ClientId": "app-1",
        "ClientSecretName": "Secret1",
        "Enabled": true
      }
    },
    "BatchSize": 100
  }
}
```

- **Throughput**: ~60 ops/sec
- **Use case**: Small to medium migrations (<100K users)
- **Advantages**: Simple setup, low complexity

**Multiple Instances (Containers/VMs)**

For large migrations, deploy multiple instances on different IPs:

```bash
# Container 1 - IP: 10.0.1.10
docker run -e CONFIG_FILE=appsettings.app1.json migration-console

# Container 2 - IP: 10.0.1.11
docker run -e CONFIG_FILE=appsettings.app2.json migration-console

# Container 3 - IP: 10.0.1.12
docker run -e CONFIG_FILE=appsettings.app3.json migration-console
```

Each configuration file has a **single, dedicated app registration**:

**appsettings.app1.json**:
```json
{
  "Migration": {
    "ExternalId": {
      "AppRegistration": {
        "ClientId": "app-1",
        "ClientSecretName": "Secret1",
        "Enabled": true
      }
    }
  }
}
```

**Benefits of Multiple Instances:**
- True process and IP isolation
- Independent failure domains
- Each instance bypasses IP throttling
- Can run on different machines/containers
- **Throughput**: N instances × 60 ops/sec = N×60 ops/sec total

**Recommended Usage:**
- Single instance: operations up to 100K users
- Multiple instances: operations over 100K users or time-sensitive cutovers


**Best Practices:**
1. Start with single instance approach
2. Monitor Application Insights for throttling metrics
3. Scale horizontally (more instances with different IPs) when needed
4. For bulk operations, use multiple console instances in containers
5. For JIT operations, let Azure Functions handle auto-scaling
6. Only deploy multiple Function Apps for extreme scale scenarios (>10K concurrent logins)

## Security Best Practices

### Secret Management

1. **Never commit secrets** to source control
2. **Use local configuration files** (gitignored) for development secrets
3. **Rotate secrets** regularly
4. **Use separate secrets** for dev/test/prod
5. **Future**: Secure secret management with Azure Key Vault will be included in v2.0

### Network Security

1. **Private endpoints only** for production (planned for v2.0)
2. **VNet integration** for Functions (planned for v2.0)
3. **NSG rules** to restrict traffic
4. **Disable public access** on Storage

### Authentication

1. **Prefer Managed Identity** over service principals
2. **Use certificate-based auth** if client secrets required
3. **Limit permissions** to minimum required
4. **Review audit logs** regularly

### Data Protection

1. **Encrypt data at rest** (enabled by default on Azure Storage)
2. **Use HTTPS only** for all communication
3. **Do not log passwords** or sensitive data
4. **Clean up export files** after migration

## Troubleshooting

### Common Errors

**Error: "Directory.Read.All permission required"**
- Solution: Grant permission in app registration and admin consent

**Error: "Throttle limit exceeded (HTTP 429)"**
- Solution: Reduce batch size or add delay between batches

**Error: "User already exists"**
- Solution: Check for duplicate users, use `B2CObjectId` to correlate

**Error: "Password does not meet complexity requirements"**
- Solution: Review `PasswordPolicy` settings and B2C password requirements

### Debugging Tips

1. **Enable verbose logging** with `--verbose` flag
2. **Check Application Insights** for detailed error traces
3. **Test with small subset** before full migration
4. **Use breakpoints** in Visual Studio/VS Code for local debugging
5. **Review Graph API responses** in telemetry

### Support Resources

- Microsoft Graph API Documentation: https://docs.microsoft.com/graph
- Azure AD B2C Documentation: https://docs.microsoft.com/azure/active-directory-b2c
- Entra External ID Documentation: https://docs.microsoft.com/entra/external-id

---

For additional support, consult your Microsoft representative or review the [operations runbook](OPERATIONS.md).
