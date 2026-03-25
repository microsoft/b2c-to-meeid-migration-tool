# B2C Migration Kit - Developer Guide

## Table of Contents

- [Overview](#overview)
- [Configuration Guide](#configuration-guide)
- [Development Workflow](#development-workflow)
  - [Running Simple Mode (Export → Import)](#running-simple-mode-export--import)
  - [Running Advanced Mode (Harvest → Worker Migrate → Phone Registration)](#running-advanced-mode-harvest--worker-migrate--phone-registration)
- [JIT Migration Implementation](#jit-migration-implementation)
- [Attribute Mapping](#attribute-mapping)
- [Migration Audit Table](#migration-audit-table)
- [Deployment](#deployment)
- [Operations & Monitoring](#operations--monitoring)
- [Troubleshooting](#troubleshooting)

## Overview

> **📋 STATUS**: This repository exemplifies the [JIT password migration mechanism](https://learn.microsoft.com/en-us/entra/external-id/customers/how-to-migrate-passwords-just-in-time?tabs=graph).

### Component Architecture

```
B2CMigrationKit.Core/       # Business logic, models, abstractions, DI registration
B2CMigrationKit.Console/    # CLI for bulk operations (6 commands across 2 modes + utilities)
B2CMigrationKit.Function/   # Azure Function for JIT authentication
```

The CLI supports two migration modes:

**Simple Mode — Export/Import** (no MFA, no queues):

| Orchestrator | Command | Description |
|---|---|---|
| `ExportOrchestrator` | `export` | Pages B2C users, writes local JSON files |
| `ImportOrchestrator` | `import` | Reads local JSON files, creates users in EEID with attribute mapping + JIT flag |

**Advanced Mode — Workers** (full MFA, parallel scaling):

| Orchestrator | Command | Description |
|---|---|---|
| `HarvestOrchestrator` | `harvest` | Pages B2C user IDs, enqueues batches to migrate queue |
| `WorkerMigrateOrchestrator` | `worker-migrate` | Dequeues IDs, fetches from B2C, creates in EEID, enqueues phone tasks |
| `PhoneRegistrationWorker` | `phone-registration` | Fetches MFA phone from B2C, registers in EEID (throttled) |

**Utilities:**

| Orchestrator | Command | Description |
|---|---|---|
| `ValidateOrchestrator` | `validate` | Checks connectivity to B2C, EEID, and Queue Storage (Advanced Mode) |

**Both modes**: `JitMigrationService` *(Azure Function)* — Validates B2C credentials on first login, returns `MigratePassword` action.

See [Architecture Guide](ARCHITECTURE_GUIDE.md) for detailed mode comparison and when to choose which.

## Configuration Guide

### Root Structure

```json
{
  "Migration": {
    "B2C": { ... },
    "ExternalId": { ... },
    "Storage": { ... },
    "Telemetry": { ... },
    "Retry": { ... },
    "MaxConcurrency": 8
  }
}
```

### MaxConcurrency

| Setting | Default | Scope |
|---------|---------|-------|
| `Migration.MaxConcurrency` | 8 | Parallel calls in worker-migrate and phone-registration |

Increase to 4–8 per instance for higher throughput. For significant scale, run **multiple instances** on separate IPs with dedicated app registrations.

### B2C Configuration

```json
"B2C": {
  "TenantId": "your-b2c-tenant-id",
  "TenantDomain": "yourtenant.onmicrosoft.com",
  "AppRegistration": {
    "ClientId": "app-id-1",
    "ClientSecretName": "B2CAppSecret1",
    "Name": "B2C App 1",
    "Enabled": true
  },
  "Scopes": [ "https://graph.microsoft.com/.default" ]
}
```

**B2C permissions by process**:

| Process | Permission | Type |
|---|---|---|
| export, harvest, worker-migrate | `User.Read.All` | Application |
| phone-registration | `UserAuthenticationMethod.Read.All` | Application |

Each worker instance needs a **dedicated** app registration on a **dedicated IP** for independent throttle quotas.

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
  }
}
```

| Process | Permission | Type |
|---|---|---|
| worker-migrate | `User.ReadWrite.All` | Application |
| phone-registration | `UserAuthenticationMethod.ReadWrite.All` | Application |

Admin consent required. `Directory.ReadWrite.All` is **NOT** required. `ExtensionAppId` = Application ID without hyphens for custom extension attributes.

### Export Configuration (Simple Mode)

```json
"Export": {
  "SelectFields": "id,userPrincipalName,displayName,givenName,surname,mail,mobilePhone,identities",
  "MaxUsers": 0,
  "FilterPattern": ""
}
```

| Setting | Default | Notes |
|---------|---------|-------|
| `SelectFields` | *(all standard)* | Comma-separated Graph `$select` fields. Include custom extension attributes here. |
| `MaxUsers` | 0 (unlimited) | Cap for smoke tests (e.g., `20`). `0` = export all. |
| `FilterPattern` | *(empty)* | OData `$filter` expression to subset users. |

Export writes to local JSON files — no Azure storage configuration needed for Simple Mode.

### Import Configuration (Simple Mode)

```json
"Import": {
  "AttributeMappings": {},
  "ExcludeFields": ["createdDateTime", "lastPasswordChangeDateTime"],
  "MigrationAttributes": {
    "StoreB2CObjectId": true,
    "SetRequireMigration": true,
    "OverwriteExtensionAttributes": false
  },
  "SkipPhoneRegistration": true
}
```

| Setting | Default | Notes |
|---------|---------|-------|
| `AttributeMappings` | `{}` | Rename custom extensions: `"b2c_attr": "eeid_attr"` |
| `ExcludeFields` | `[]` | Attributes to drop during import |
| `StoreB2CObjectId` | `true` | Saves original B2C objectId as extension attribute |
| `SetRequireMigration` | `true` | Marks users for JIT password migration |
| `OverwriteExtensionAttributes` | `false` | If `true`, overwrites existing extension values |
| `SkipPhoneRegistration` | `true` | Simple Mode skips MFA phone migration (use Advanced Mode if needed) |

Import reads from local JSON files exported in Step 1. Audit defaults to local JSONL (`AuditMode="File"`).

### Harvest Configuration

```json
"Harvest": {
  "QueueName": "user-ids-to-process",
  "IdsPerMessage": 20,
  "PageSize": 999,
  "MessageVisibilityTimeout": "00:30:00"
}
```

### Phone Registration Configuration

```json
"PhoneRegistration": {
  "QueueName": "phone-registration",
  "ThrottleDelayMs": 400,
  "MessageVisibilityTimeoutSeconds": 120,
  "EmptyQueuePollDelayMs": 5000,
  "MaxEmptyPolls": 3
}
```

| Setting | Default | Notes |
|---|---|---|
| `ThrottleDelayMs` | 400 ms | Increase if sustained 429s. Scale by adding workers with separate app registrations. |
| `MessageVisibilityTimeoutSeconds` | 120 s | Message reappears after this timeout on crash |
| `MaxEmptyPolls` | 3 | CLI exits after N empty polls |
| `UseFakePhoneWhenMissing` | false | **Load-test only.** Generates synthetic `+1555XXXXXXX` numbers. ⚠️ NEVER in production. |

### Storage Configuration

```json
"Storage": {
  "ConnectionStringOrUri": "UseDevelopmentStorage=true",
  "AuditTableName": "migrationAudit",
  "UseManagedIdentity": false,
  "AuditMode": "File"
}
```

| AuditMode | Backend | Notes |
|---|---|---|
| `File` | Local JSONL file (`AuditFilePath`) | **Default.** Thread-safe, no Azure dependency. |
| `Table` | Azure Table Storage / Azurite | Optional. Queryable, production-grade. Requires `Storage Table Data Contributor` role. |
| `None` | No-op | Smoke tests only. |

Required roles (Advanced Mode): `Storage Queue Data Contributor`. Add `Storage Table Data Contributor` only if using `AuditMode="Table"`.

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

```json
"Telemetry": {
  "Enabled": true,
  "UseConsoleLogging": true
}
```

Key metrics: `harvest.users.enqueued`, `WorkerMigrate.UserCreated/Duplicate/Failed`, `PhoneRegistration.Success/Failed/Completed`, `JITAuth.PasswordValidated`.

## Development Workflow

### Prerequisites

- .NET 8.0 SDK, Azure Functions Core Tools v4, Azure CLI
- VS Code with C# Dev Kit

### Local Setup

**Simple Mode** (Export/Import):
```bash
cd src/B2CMigrationKit.Console
cp appsettings.export-import.example.json appsettings.export-import.json
# Edit with your tenant credentials
```

**Advanced Mode** (Workers):
```bash
cd src/B2CMigrationKit.Console
cp appsettings.master.example.json appsettings.master.json
cp appsettings.user-worker.example.json appsettings.user-worker.json
cp appsettings.phone-worker.example.json appsettings.phone-worker.json
# Edit each file with your tenant credentials
```

Config patterns: **Local** → `ClientSecret` with actual value. **Production** → `ClientSecretName` with Key Vault secret name.

### Running Simple Mode (Export → Import)

Two commands, no queues. Best for small & medium tenant, < 1 million users without MFA phone migration.

**1. Export** — pages B2C users to local JSON files.
```powershell
dotnet run -- export --config appsettings.export-import.json

# Smoke test: set Export.MaxUsers to 20 in config first
```

**2. Import** — reads exported local JSON files, creates users in EEID.
```powershell
dotnet run -- import --config appsettings.export-import.json
```

Users are created with random passwords + `RequiresMigration=true` (JIT handles real password on first login). Existing users recorded as `Duplicate`.

### Running Advanced Mode (Harvest → Worker Migrate → Phone Registration)

Three-stage pipeline with Azure Queues. Best for large tenants and MFA phone migration.

**1. Harvest** — enqueues B2C user IDs. Use `MaxUsers` in config to cap (e.g., `20` for smoke test).
```powershell
.\scripts\Start-LocalHarvest.ps1
```

**2. Worker Migrate** — fetches profiles, creates EEID users, enqueues phone tasks.
```powershell
# Single instance (smoke test)
.\scripts\Start-LocalWorkerMigrate.ps1 -ConfigFile appsettings.user-worker.json -VerboseLogging

# Parallel (separate terminal per instance, each with different app registrations)
.\scripts\Start-LocalWorkerMigrate.ps1 -ConfigFile appsettings.user-worker.json
```

Workers auto-exit when queue is empty. Existing users recorded as `Duplicate` (phone task still enqueued).

**3. Phone Registration** — drains phone queue, registers MFA phones in EEID.
```powershell
# Single instance
.\scripts\Start-LocalPhoneRegistration.ps1 -VerboseLogging

# Parallel (separate terminal per instance, each with different app registrations)
.\scripts\Start-LocalPhoneRegistration.ps1 -ConfigFile appsettings.phone-registration.json
.\scripts\Start-LocalPhoneRegistration.ps1 -ConfigFile appsettings.phone-registration2.json
```

409 Conflict = success (idempotent). Users without MFA phone → `PhoneSkipped`.

### Building

```bash
dotnet build              # all projects
dotnet build -c Release   # release build
```

## Bulk Migration Pipeline Reference

Detailed technical reference for each pipeline step — permissions, configuration, and audit fields.

### Simple Mode — Export

Pages B2C users with configurable `$select` fields, writes each page as a local JSON file. Supports optional `FilterPattern` for client-side filtering by `displayName`/`userPrincipalName`.

- **Permissions**: B2C `User.Read.All` (Application)
- **Config**: `Export.SelectFields`, `Export.FilterPattern`, `PageSize` (default: 999)
- **Output**: Local JSON files (`exports/page-{N}.json`)

### Simple Mode — Import

Reads exported local JSON files sequentially, transforms user profiles (UPN domain rewrite, extension attribute mapping, email identity, random password + `RequiresMigration` JIT flag), creates users in EEID. Audit results written to local JSONL files by default (`AuditMode="File"`); optionally to Azure Table Storage (`AuditMode="Table"`).

- **Permissions**: EEID `User.ReadWrite.All` (Application)
- **Config**: `Import.ExtensionAttributes` (source → target attribute mapping)
- **Idempotency**: 409 Conflict = duplicate, skipped gracefully

### Advanced Mode — Harvest

Pages B2C with `$select=id` (~10× cheaper than full profile fetch), splits into batches of `IdsPerMessage` (default: 20), enqueues to `user-ids-to-process`. Single instance, exits on completion.

- **Permissions**: B2C `User.Read.All` (Application) — read-only, no EEID access needed
- **Config**: `HarvestOptions.PageSize` (default: 999), `HarvestOptions.IdsPerMessage` (default: 20)

### Advanced Mode — Worker Migrate

Consumes harvest queue, fetches full profiles via `$batch`, transforms and creates users in EEID, enqueues phone tasks.

**Per-message flow**: Dequeue (20 IDs) → `$batch` fetch from B2C → Transform (UPN, attrs, email identity, random password) → `POST /users` to EEID → Audit → Enqueue phone task → Delete message.

**Audit trail** (local JSONL by default; optional Azure Table `migration-audit` when `AuditMode="Table"`):

| Field | Description |
|---|---|
| `PartitionKey` | Date `yyyyMMdd` |
| `RowKey` | `migrate_{B2CObjectId}` |
| `Status` | `Created` / `Duplicate` / `Failed` |
| `ErrorCode` | HTTP status or exception type |
| `ErrorMessage` | Truncated to 4 KB |
| `DurationMs` | API call duration |

**Permissions**: B2C `User.Read.All`, EEID `User.ReadWrite.All` (both Application).

### Advanced Mode — Phone Registration

Registers MFA phone numbers in EEID so users confirm (not re-register) on first JIT login.

Queue messages contain only `{ B2CUserId, EEIDUpn }` — phone numbers are fetched at drain time (PII never persisted in queue).

| Setting | Default | Purpose |
|---|---|---|
| `ThrottleDelayMs` | 400 ms | Rate control — increase if sustained 429s |
| `MessageVisibilityTimeoutSeconds` | 120 s | Retry delay on failure |
| `MaxEmptyPolls` | 3 | Exit after N consecutive empty polls |

**Permissions**: B2C `UserAuthenticationMethod.Read.All`, EEID `UserAuthenticationMethod.ReadWrite.All` (both Application).

---

## JIT Migration Implementation

⏱️ **Quick Start**: ~15 minutes to set up local testing environment

### How JIT Works

Users migrated via bulk migration have random passwords and `RequiresMigration = true`. On first login:

1. User enters real B2C password → EEID doesn't match → triggers Custom Authentication Extension
2. Azure Function validates password against B2C via ROPC flow
3. If valid → updates EEID password, sets `RequiresMigration = false`
4. Subsequent logins authenticate directly against EEID

### Step 1: Generate RSA Key Pair

```powershell
# Option A: Automation script (recommended)
.\scripts\New-LocalJitRsaKeyPair.ps1 -OutputPath ".\scripts\keys"

# Option B: Manual
openssl genrsa -out private_key.pem 2048
openssl rsa -in private_key.pem -pubout -out public_key.pem
```

Output: `jit-private-key.pem`, `jit-public-key.jwk.json`, `jit-certificate.txt`, `jit-public-key-x509.txt`

### Step 2: Configure local.settings.json

Create `src/B2CMigrationKit.Function/local.settings.json`:

```json
{
  "IsEncrypted": false,
  "Values": {
    "AzureWebJobsStorage": "UseDevelopmentStorage=true",
    "FUNCTIONS_WORKER_RUNTIME": "dotnet-isolated",
    "Migration__B2C__TenantId": "YOUR_B2C_TENANT_ID",
    "Migration__B2C__TenantDomain": "YOUR_B2C_TENANT.onmicrosoft.com",
    "Migration__B2C__AppRegistration__ClientId": "YOUR_CLIENT_ID",
    "Migration__B2C__AppRegistration__ClientSecret": "YOUR_SECRET",
    "Migration__B2C__AppRegistration__Name": "B2C ROPC App",
    "Migration__B2C__AppRegistration__Enabled": "true",
    "Migration__ExternalId__TenantId": "YOUR_EEID_TENANT_ID",
    "Migration__ExternalId__TenantDomain": "YOUR_EEID_TENANT.onmicrosoft.com",
    "Migration__ExternalId__ExtensionAppId": "YOUR_EXTENSION_APP_ID_NO_DASHES",
    "Migration__ExternalId__AppRegistration__ClientId": "YOUR_EEID_CLIENT_ID",
    "Migration__ExternalId__AppRegistration__ClientSecret": "YOUR_EEID_SECRET",
    "Migration__ExternalId__AppRegistration__Name": "External ID App",
    "Migration__ExternalId__AppRegistration__Enabled": "true",
    "Migration__JitAuthentication__UseKeyVault": "false",
    "Migration__JitAuthentication__TestMode": "true",
    "Migration__JitAuthentication__InlineRsaPrivateKey": "-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----",
    "Migration__JitAuthentication__CachePrivateKey": "true",
    "Migration__JitAuthentication__TimeoutSeconds": "1.5"
  }
}
```

> Azure Functions uses flat `__`-separated keys. See `local.settings.example.json` for a complete template. `TestMode: true` skips B2C validation for testing without B2C access.

### Step 3: Start Function with ngrok

```powershell
cd src\B2CMigrationKit.Function
.\start-local.ps1
```

The script builds the function, starts ngrok tunnel, starts the function on port 7071, and copies the endpoint URL to clipboard.

**Manual alternative**:
```powershell
# Terminal 1
ngrok http 7071
# Terminal 2
cd src\B2CMigrationKit.Function && func start
```

**VS Code debugging**: Press F5 → "Attach to .NET Functions" → select the `dotnet` process. Useful breakpoints: `JitAuthenticationFunction.cs:60` (parse payload), `JitMigrationService.cs:73` (check migration status), `JitMigrationService.cs:125` (ROPC validation).

### Step 4: Configure Custom Authentication Extension

**Prerequisites**: RSA keys generated, local.settings.json configured, users imported with `RequiresMigration=true`, function running with ngrok.

**Sub-Step 1**: Create app registration in External ID tenant. Record Application ID, Object ID. Create client secret.

**Sub-Step 2**: Upload RSA public key via Graph API (Portal doesn't support custom key upload):

```powershell
$publicKeyJwk = Get-Content ".\scripts\keys\jit-public-key.jwk.json" -Raw | ConvertFrom-Json
$customExtensionAppObjectId = "PASTE_OBJECT_ID"
$token = (az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv)

$body = @{
    keyCredentials = @(@{
        type = "AsymmetricX509Cert"; usage = "Verify"
        key = [Convert]::ToBase64String([System.Text.Encoding]::UTF8.GetBytes($publicKeyJwk | ConvertTo-Json -Compress))
        displayName = "JIT Migration RSA Public Key"
        customKeyIdentifier = [System.Text.Encoding]::UTF8.GetBytes($publicKeyJwk.kid)
    })
    tokenEncryptionKeyId = $publicKeyJwk.kid
} | ConvertTo-Json -Depth 10

Invoke-RestMethod -Method Patch `
    -Uri "https://graph.microsoft.com/beta/applications/$customExtensionAppObjectId" `
    -Headers @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" } `
    -Body $body
```

**Sub-Step 3**: Create Custom Authentication Extension resource:

```powershell
$ngrokUrl = "https://your-domain.ngrok.app"
$customExtensionAppClientId = "PASTE_CLIENT_ID"
$token = (az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv)

$body = @{
    "@odata.type" = "#microsoft.graph.onPasswordSubmitCustomExtension"
    displayName = "JIT Password Migration Extension"
    targetUrl = "$ngrokUrl/api/JitAuthentication"
    authenticationConfiguration = @{
        "@odata.type" = "#microsoft.graph.azureAdTokenAuthentication"
        resourceId = "api://$customExtensionAppClientId"
    }
} | ConvertTo-Json -Depth 10

$response = Invoke-RestMethod -Method Post `
    -Uri "https://graph.microsoft.com/beta/identity/customAuthenticationExtensions" `
    -Headers @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" } `
    -Body $body

$response.id | Out-File "custom-extension-id.txt"
```

**Sub-Step 4**: Create OnPasswordSubmit Listener:

```powershell
$extensionAppId = "YOUR_APP_ID_NO_DASHES"
$extensionId = Get-Content "custom-extension-id.txt"
$token = (az account get-access-token --resource https://graph.microsoft.com --query accessToken -o tsv)

$body = @{
    "@odata.type" = "#microsoft.graph.onPasswordSubmitListener"
    priority = 500
    conditions = @{ applications = @{ includeAllApplications = $true } }
    handler = @{
        "@odata.type" = "#microsoft.graph.onPasswordMigrationCustomExtensionHandler"
        migrationPropertyId = "extension_${extensionAppId}_RequiresMigration"
        customExtension = @{ id = $extensionId }
    }
} | ConvertTo-Json -Depth 10

Invoke-RestMethod -Method Post `
    -Uri "https://graph.microsoft.com/beta/identity/authenticationEventListeners" `
    -Headers @{ Authorization = "Bearer $token"; "Content-Type" = "application/json" } `
    -Body $body
```

### Step 5: Test JIT Flow

```http
POST https://your-domain.ngrok.app/api/JitAuthentication
Content-Type: application/json

{
  "type": "customAuthenticationExtension",
  "data": {
    "authenticationContext": {
      "correlationId": "test-12345",
      "user": { "id": "user-object-id", "userPrincipalName": "testuser@yourdomain.com" }
    },
    "passwordContext": { "userPassword": "RealB2CPassword123!", "nonce": "test-nonce" }
  }
}
```

Expected response (TestMode=true): `{ "data": { "actions": [{ "@odata.type": "microsoft.graph.customAuthenticationExtension.migratePassword" }] } }`

**ngrok web UI** at `http://localhost:4040` — inspect requests, replay errors, filter by path/status.

### JIT Troubleshooting

| Issue | Solution |
|-------|---------|
| **JIT not triggering** | Verify `RequiresMigration = true` and user has random (not real) password. Check listener is created. |
| **ngrok URL changed** | Use `.\scripts\Configure-ExternalIdJit.ps1` to update, or use ngrok static domain. |
| **Function timeout (2s)** | Set `TimeoutSeconds: 1.5`, `CachePrivateKey: true`, `Retry.MaxRetries: 1`. Target <1500ms p95. |
| **TestMode in production** | ⚠️ **Security risk** — any password accepted. Set `TestMode=false` immediately. |
| **User not found** | Check userId in payload, verify user exists in EEID, check app permissions. |
| **B2C validation failed** | Verify ROPC policy exists (`B2C_1_ROPC`), test B2C login directly via curl, check UPN transformation. |

> **Reference**: `src/B2CMigrationKit.Function/sample/sample.cs` contains a standalone reference implementation showing the raw Custom Authentication Extension contract.

## Attribute Mapping

### Overview

Most Graph User attributes copy directly. Configure mappings only for custom extension attributes with different names between tenants.

### Export Configuration

```json
"Export": {
  "SelectFields": "id,userPrincipalName,displayName,givenName,surname,mail,mobilePhone,identities,extension_abc123_CustomerId"
}
```

### Import Configuration

```json
"Import": {
  "AttributeMappings": {
    "extension_b2c_LegacyId": "extension_extid_CustomerId"
  },
  "ExcludeFields": ["createdDateTime"],
  "MigrationAttributes": {
    "StoreB2CObjectId": true,
    "B2CObjectIdTarget": "extension_xyz_OriginalB2CId",
    "SetRequireMigration": true,
    "RequireMigrationTarget": "extension_xyz_RequiresMigration"
  }
}
```

**Behavior**: Mapped attributes → renamed. Unmapped attributes → copied as-is. Excluded attributes → skipped.

### UPN and Email Identity Transformation

These transformations are **automatic** (not configurable via attribute mapping):

**UPN Domain Transform** (`WorkerMigrateOrchestrator.cs:TransformUpn()`):
- Extracts local part, removes `#EXT#` markers, replaces domain with EEID domain
- Preserves local part for JIT reverse lookup (workaround for [sign-in alias](https://learn.microsoft.com/en-us/entra/external-id/customers/how-to-sign-in-alias))
- Empty local part after cleaning → GUID-based identifier

**Email Identity** (`EnsureEmailIdentity()`):
- Has `emailAddress` identity → keep it
- Has `mail` field → create `emailAddress` identity from it
- No `mail` → use UPN as fallback (logs warning)

All identity `issuer` fields updated from B2C to EEID domain. Standard fields (`mobilePhone`, `displayName`, etc.) copied automatically.

### Prerequisites

Create target custom attributes in External ID (**Azure Portal → External Identities → Custom user attributes**) before import. Full attribute name format: `extension_{ExtensionAppId}_{attributeName}`.

## Migration Audit

Every user processed is recorded in the audit trail. By default, audit records are written to local JSONL files (`AuditMode="File"`). Optionally, set `AuditMode="Table"` to write to Azure Table Storage (`migrationAudit`) for queryable audit:

| Column | Description |
|---|---|
| `PartitionKey` | Run date `yyyyMMdd` |
| `RowKey` | `{stage}_{B2CObjectId}` (stage = `migrate` or `phone`) |
| `Status` | `Created` / `Duplicate` / `Failed` / `PhoneRegistered` / `PhoneSkipped` |
| `DurationMs` | Graph API call duration |
| `ErrorCode` | OData error code (failures only) |
| `ErrorMessage` | Error detail (failures only) |

Table is auto-created. View via Azure Portal (Storage → Tables), Azure Storage Explorer, or CLI:

```bash
az storage entity query --account-name <acct> --table-name migrationAudit --filter "Status eq 'Failed'" --output table
```

**Security**: Contains B2C objectId and status only — no passwords, no PII beyond objectId.

## Deployment

### JIT Function Deployment

```bash
cd src/B2CMigrationKit.Function
dotnet publish -c Release
func azure functionapp publish func-b2c-migration
az functionapp restart --name func-b2c-migration --resource-group rg-b2c-migration
```

> Always restart after deployment to load new binaries.

### Bulk Migration Infrastructure

Infrastructure deploys via `Deploy-All.ps1`. See [`infra/README.md`](../infra/README.md) for full details and [`docs/RUNBOOK.md`](RUNBOOK.md) for a step-by-step operations guide.

**Quick start**:

1. Generate SSH key: `ssh-keygen -t ed25519 -f scripts/b2c-mig-deploy -C "b2c-migration"`
2. Create app registrations per worker: `.\scripts\Setup-Migration.ps1` (or manually)
3. Generate Azure configs: `.\scripts\Initialize-MigrationEnvironment.ps1 -MasterCount 1 -UserWorkerCount 2 -PhoneWorkerCount 2 -StorageAccountName <name> -Force`
4. Deploy infra + VMs: `.\scripts\Deploy-All.ps1 -ResourceGroup rg-b2c-eeid-mig-test1 -SshPublicKeyFile .\scripts\b2c-mig-deploy.pub`
5. Connect via Bastion: `.\scripts\Connect-Worker.ps1 -WorkerIndex 1`
6. SSH: `ssh -p 2201 -i .\scripts\b2c-mig-deploy azureuser@localhost`
7. Configure each VM: `bash /opt/b2c-migration/repo/scripts/Configure-Worker.sh` (interactive) or `--config-file` (non-interactive)
8. Run migration (see [Runbook](RUNBOOK.md))

## Operations & Monitoring

### Audit

The primary observability source is the local JSONL audit files (default `AuditMode="File"`). Each line tracks one user migration with status, timestamps, and error details.

If using `AuditMode="Table"` (Azure Table Storage), query via CLI:
```bash
az storage entity query --table-name MigrationAudit \
  --account-name <storage> --auth-mode login \
  --filter "Status eq 'Failed'"
```

Or use Azure Storage Explorer for visual browsing.

### Console Logging

Connect to a worker via Bastion SSH to see real-time stdout. Enable `--verbose` for detailed Graph API call logging.

### Scaling

Scale by adding worker VMs (increase `-UserWorkerCount` and/or `-PhoneWorkerCount` parameters in Deploy-All.ps1). Each worker needs a dedicated app registration with distinct IPs to avoid per-IP soft limits. See [Architecture Guide](ARCHITECTURE_GUIDE.md) § 9.

## Troubleshooting

| Error | Solution |
|-------|---------|
| HTTP 429 (throttle) | Reduce `MaxConcurrency`, increase `ThrottleDelayMs`, or add workers with separate app regs |
| "User already exists" | Check for duplicates, use `B2CObjectId` to correlate. Handled as `Duplicate` status. |
| High latency, zero 429s | Soft concurrency ceiling hit. Reduce `MaxConcurrency`. |

**Tips**: Enable `--verbose` logging, check Table Storage audit records, test with small subsets first, use VS Code breakpoints for local debugging.

### Resources

- [Microsoft Graph API](https://docs.microsoft.com/graph)
- [Azure AD B2C](https://docs.microsoft.com/azure/active-directory-b2c)
- [Entra External ID](https://docs.microsoft.com/entra/external-id)
