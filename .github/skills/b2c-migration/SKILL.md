---
name: b2c-migration
description: "Configure and run B2C to Entra External ID user migration. USE FOR: setup migration, configure B2C migration, run export import, run harvest workers, configure JIT password migration, create app registrations, generate RSA keys, set up devtunnel, test JIT flow, manage migration flags, validate readiness, deploy workers to Azure, analyze telemetry, phone registration, bulk migration, export B2C apps, transform API connectors to CAE. DO NOT USE FOR: general Azure questions, Entra ID concepts unrelated to migration."
argument-hint: "Describe what migration step you need help with"
---

# B2C to Entra External ID Migration Kit

This skill guides an agent through configuring, running, and troubleshooting the B2C Migration Kit — a tool for migrating users from Azure AD B2C to Microsoft Entra External ID.

## Architecture Overview

```
B2CMigrationKit.Core/       # Business logic, models, abstractions
B2CMigrationKit.Console/    # CLI for bulk operations (export, import, harvest, worker-migrate, phone-registration, validate)
B2CMigrationKit.Function/   # Azure Function for JIT password migration
```

Two migration modes:

| Mode | Best For | Steps |
|------|----------|-------|
| **Simple** (Export/Import) | < 1M users, no MFA phone migration | `export` → `import` |
| **Advanced** (Workers) | Large tenants, MFA phone, parallel scaling | `harvest` → `worker-migrate` → `phone-registration` |

Both modes use **JIT password migration** for seamless first-login password transfer.

## Decision Flow

When the user asks for help, determine which phase they need:

| User Intent | Procedure |
|-------------|-----------|
| First-time setup, don't know where to start | [Full Setup Wizard](#full-setup-wizard) |
| Configure tenants, create app registrations | [Setup & App Registrations](#setup-and-app-registrations) |
| Run Simple Mode (export/import) | [Simple Mode](#simple-mode-export-import) |
| Run Advanced Mode (workers) | [Advanced Mode](#advanced-mode-harvest-workers-phone) |
| Configure JIT password migration | [JIT Configuration](#jit-password-migration-configuration) |
| Test JIT locally | [Local JIT Testing](#local-jit-testing) |
| Manage RequiresMigration flags | [Migration Flag Management](#migration-flag-management) |
| Validate before migration | [Readiness Validation](#readiness-validation) |
| Deploy to Azure VMs | [Azure Deployment](#azure-deployment) |
| Analyze results | [Telemetry & Analysis](#telemetry-and-analysis) |
| Migrate B2C apps / API connectors | [App & Connector Migration](#app-and-connector-migration) |

## Full Setup Wizard

Run the interactive wizard for end-to-end setup. This is the recommended starting point.

```powershell
.\scripts\Setup-Migration.ps1
```

The wizard:
1. Collects B2C and External ID tenant info (TenantId, TenantDomain, ExtensionAppId)
2. Creates app registrations with correct permissions via device code auth
3. Generates all configuration files
4. Optionally deploys Azure infrastructure

Non-interactive mode for automation:
```powershell
.\scripts\Setup-Migration.ps1 -NonInteractive `
    -B2CTenantId "<guid>" -B2CTenantDomain "<tenant>.onmicrosoft.com" `
    -EeidTenantId "<guid>" -EeidTenantDomain "<tenant>.onmicrosoft.com" `
    -ExtensionAppId "<32-hex-chars-no-hyphens>" `
    -WorkerCount 4 -Mode Advanced -Target Local
```

Dry run: `.\scripts\Setup-Migration.ps1 -WhatIf`

## Setup and App Registrations

### Prerequisites

- .NET 8.0 SDK
- Azure Functions Core Tools v4
- PowerShell 7.0+
- Azure CLI (`az login`)
- VS Code with C# Dev Kit and Azurite extension

### Required Permissions

**B2C tenant app registrations:**

| Process | Permission | Type |
|---------|------------|------|
| export, harvest, worker-migrate | `User.Read.All` | Application |
| phone-registration | `UserAuthenticationMethod.Read.All` | Application |

**External ID tenant app registrations:**

| Process | Permission | Type |
|---------|------------|------|
| import, worker-migrate | `User.ReadWrite.All` | Application |
| phone-registration | `UserAuthenticationMethod.ReadWrite.All` | Application |

Admin consent required on all permissions. Each parallel worker instance needs a **dedicated** app registration on a **dedicated IP** for independent throttle quotas.

### ExtensionAppId

The `ExtensionAppId` is the Application ID of the `b2c-extensions-app` (32 hex characters, no hyphens). Custom extension attributes use format: `extension_{ExtensionAppId}_{attributeName}`.

### Configuration Files

**Simple Mode:**
```powershell
cd src/B2CMigrationKit.Console
Copy-Item appsettings.export-import.example.json appsettings.export-import.json
# Edit with tenant credentials
```

**Advanced Mode:**
```powershell
cd src/B2CMigrationKit.Console
Copy-Item appsettings.master.example.json appsettings.master.json
Copy-Item appsettings.user-worker.example.json appsettings.user-worker.json
Copy-Item appsettings.phone-worker.example.json appsettings.phone-worker.json
# Edit each file with tenant credentials
```

Config patterns:
- **Local** → use `ClientSecret` with actual value
- **Production** → use `ClientSecretName` with Key Vault secret name

### Configuration Structure

See [configuration-reference.md](./references/configuration-reference.md) for the full JSON schema and all settings.

## Readiness Validation

Always run validation before starting a migration:

```powershell
# Simple Mode
.\scripts\Validate-MigrationReadiness.ps1

# Worker Mode
.\scripts\Validate-MigrationReadiness.ps1 -Mode worker -ConfigFile "appsettings.worker1.json"
```

Checks: config validity, Graph API connectivity to both tenants, permissions, extension attributes, storage reachability, .NET SDK version.

## Simple Mode (Export Import)

**Step 1: Start Azurite** — `Ctrl+Shift+P` → `Azurite: Start Service`

**Step 2: Export** — pages all B2C users to local JSON files:
```powershell
.\scripts\Start-LocalExport.ps1
# Smoke test: set Export.MaxUsers to 20 in config first
```

**Step 3: Import** — creates users in External ID:
```powershell
.\scripts\Start-LocalImport.ps1
```

Users are created with random passwords + `RequireMigration=true`. JIT handles real password on first login.

## Advanced Mode (Harvest Workers Phone)

**Step 1: Start Azurite** — `Ctrl+Shift+P` → `Azurite: Start Service`

**Step 2: Harvest** — enqueues B2C user IDs:
```powershell
.\scripts\Start-LocalHarvest.ps1
```

**Step 3: Worker Migrate** — fetches profiles, creates EEID users, enqueues phone tasks:
```powershell
# Single instance
.\scripts\Start-LocalWorkerMigrate.ps1 -ConfigFile appsettings.worker1.json -VerboseLogging

# Parallel (separate terminal per instance)
.\scripts\Start-LocalWorkerMigrate.ps1 -ConfigFile appsettings.worker1.json
.\scripts\Start-LocalWorkerMigrate.ps1 -ConfigFile appsettings.worker2.json
```

**Step 4: Phone Registration** — registers MFA phones in EEID:
```powershell
.\scripts\Start-LocalPhoneRegistration.ps1 -VerboseLogging
```

Common parameters for all scripts: `-ConfigFile <path>`, `-VerboseLogging`, `-SkipAzurite`

## JIT Password Migration Configuration

JIT migrates passwords seamlessly on each user's first login. This section covers the full setup.

### Step 1: Generate RSA Keys

```powershell
.\scripts\New-LocalJitRsaKeyPair.ps1 -OutputPath ".\scripts\keys"
```

Generates: `jit-private-key.pem`, `jit-public-key.jwk.json`, `jit-certificate.txt`, `jit-public-key-x509.txt`

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
    "Migration__JitAuthentication__TestMode": "false",
    "Migration__JitAuthentication__InlineRsaPrivateKey": "-----BEGIN PRIVATE KEY-----\n...\n-----END PRIVATE KEY-----",
    "Migration__JitAuthentication__CachePrivateKey": "true",
    "Migration__JitAuthentication__TimeoutSeconds": "1.5"
  }
}
```

> `TestMode: true` skips B2C password validation — use ONLY for testing without B2C access. **Never in production.**

### Step 3: Configure External ID (Automated)

Use the automation script:

```powershell
.\scripts\Configure-ExternalIdJit.ps1 `
    -TenantId "your-external-id-tenant-id" `
    -CertificatePath ".\scripts\keys\jit-certificate.txt" `
    -FunctionUrl "https://your-devtunnel-url.devtunnels.ms/api/JitAuthentication" `
    -MigrationPropertyId "extension_{ExtensionAppId}_RequireMigration"
```

This script performs via device code flow:
1. Creates Custom Authentication Extension app registration + encryption cert upload
2. Configures Application ID URI matching the function URL domain
3. Creates the Custom Authentication Extension resource (onPasswordSubmitCustomExtension)
4. Creates a test client app with redirect to `https://jwt.ms`
5. Creates the event listener (onPasswordSubmitListener)

**Manual step required:** Grant admin consent for the Extension App in Azure Portal after the script completes.

### Step 4: Switch Environments

Toggle JIT between local devtunnel and Azure Function endpoints:
```powershell
.\scripts\Switch-JitEnvironment.ps1 -Environment Local   # devtunnel
.\scripts\Switch-JitEnvironment.ps1 -Environment Azure    # production
```

## Local JIT Testing

### Start the Function

```powershell
cd src\B2CMigrationKit.Function
.\start-local.ps1
```

### Expose with VS Code Port Forwarding

1. `Ctrl+Shift+P` → `Ports: Forward a Port` → enter `7071`
2. Right-click the forwarded port in **Ports** panel → **Port Visibility** → **Public**
3. Copy the **Forwarded Address** (e.g., `https://abc123-7071.brs.devtunnels.ms`)

The JIT endpoint is: `<forwarded-url>/api/JitAuthentication`

> The devtunnel URL is stable for the VS Code session. If it changes, update the Custom Authentication Extension with `Configure-ExternalIdJit.ps1` or `Switch-JitEnvironment.ps1`.

### Important: Application ID URI Must Match

The Application ID URI of the Custom Extension app registration **must match** the devtunnel domain. Format: `api://<devtunnel-host>/<app-client-id>`. The `Configure-ExternalIdJit.ps1` script sets this automatically, but if you change the tunnel URL, update it:

```powershell
# Via Switch-JitEnvironment.ps1
.\scripts\Switch-JitEnvironment.ps1 -Environment Local `
    -TenantId "<eeid-tenant-id>" `
    -ExtensionId "<cae-id>" `
    -LocalAppObjectId "<app-object-id>" `
    -LocalAppId "<app-client-id>" `
    -NgrokDomain "<devtunnel-host>"
```

### Test via Direct HTTP

```http
POST https://<devtunnel-url>/api/JitAuthentication
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

### Test via User Flow

1. Azure Portal → External ID tenant → User flows
2. Select the user flow associated with the test client app
3. Click **Run user flow**
4. Sign in with a migrated user's email and their original B2C password

### JIT Troubleshooting

| Issue | Solution |
|-------|---------|
| JIT not triggering | Verify `RequireMigration = true` on the user and check the event listener exists |
| Tunnel URL changed | Use `Configure-ExternalIdJit.ps1` or `Switch-JitEnvironment.ps1` to update |
| Function timeout (>2s) | Set `TimeoutSeconds: 1.5`, `CachePrivateKey: true`, `Retry.MaxRetries: 1` |
| TestMode in production | **Security risk** — any password accepted. Set `TestMode=false` immediately |
| User not found | Check userId in payload, verify user exists in EEID, check app permissions |
| B2C validation failed | Verify ROPC policy exists (`B2C_1_ROPC`), test B2C login directly, check UPN transformation |
| DomainNameDoesNotMatch | Application ID URI domain must match the targetUrl domain in the CAE |

## Migration Flag Management

Query and update the `RequireMigration` flag on External ID users:

```powershell
# List users pending migration
.\scripts\Manage-MigrationFlag.ps1

# List all users
.\scripts\Manage-MigrationFlag.ps1 -Filter all

# Clear flag for migrated users
.\scripts\Manage-MigrationFlag.ps1 -Filter true -SetFlag false

# Set flag for a specific user by ID
.\scripts\Manage-MigrationFlag.ps1 -UserId "<user-object-id>" -SetFlag true

# Set flag for a specific user by UPN
.\scripts\Manage-MigrationFlag.ps1 -UserUpn "user@tenant.onmicrosoft.com" -SetFlag true

# Discover extension attribute names in the tenant
.\scripts\Manage-MigrationFlag.ps1 -Discover

# Preview changes without applying
.\scripts\Manage-MigrationFlag.ps1 -Filter true -SetFlag false -WhatIf
```

## Azure Deployment

Deploy migration infrastructure to Azure VMs:

```powershell
# Generate SSH key
ssh-keygen -t ed25519 -f scripts/b2c-mig-deploy -C "b2c-migration"

# Full deployment
.\scripts\Deploy-All.ps1 -ResourceGroup rg-b2c-eeid-mig `
    -SshPublicKeyFile .\scripts\b2c-mig-deploy.pub

# Custom worker counts
.\scripts\Deploy-All.ps1 -ResourceGroup rg-b2c-eeid-mig `
    -SshPublicKeyFile .\scripts\b2c-mig-deploy.pub `
    -MasterCount 1 -UserWorkerCount 4 -PhoneWorkerCount 3

# Re-provision VMs only (infra already deployed)
.\scripts\Deploy-All.ps1 -ResourceGroup rg-b2c-eeid-mig `
    -SshPublicKeyFile .\scripts\b2c-mig-deploy.pub -SkipInfra
```

After deployment, connect via Bastion and configure each VM:
```powershell
# Open tunnel
.\scripts\Connect-Worker.ps1 -WorkerIndex 1

# SSH through tunnel (separate terminal)
ssh -p 2201 -i .\scripts\b2c-mig-deploy azureuser@localhost

# On the VM: configure worker
bash /opt/b2c-migration/repo/scripts/Configure-Worker.sh
```

## App and Connector Migration

Migrate B2C app registrations and transform API connectors to Custom Authentication Extensions:

```powershell
# Export from B2C
.\scripts\Export-B2CApps.ps1 -TenantId "contosob2c.onmicrosoft.com"

# Import to External ID
.\scripts\Import-EeidApps.ps1 -TargetTenantId "contosoeeid.onmicrosoft.com" `
    -InputFile "app-migration-export.json"

# Dry run
.\scripts\Import-EeidApps.ps1 -TargetTenantId "contosoeeid.onmicrosoft.com" -DryRun
```

> **Auth model change:** B2C API connectors use Basic Auth / Client Certificate / API Key. External ID CAEs use Azure AD bearer tokens. Update your API endpoints to validate Azure AD tokens after migration.

## Telemetry and Analysis

### Live Monitoring

```powershell
.\scripts\Watch-Migration.ps1 -WorkerCount 8 -RefreshSeconds 2
```

### Download from VMs

```powershell
.\scripts\Download-Telemetry.ps1 -WorkerCount 5 -OutputDir ./telemetry
```

### Analyze Results

```powershell
.\scripts\Analyze-Telemetry.ps1 -WorkerCount 5
```

Report includes: latency percentiles (p50/p90/p95/p99), throughput, 429 throttle counts, failure breakdown, cross-pipeline coverage.

## Key Configuration Reference

| Setting | Location | Description |
|---------|----------|-------------|
| `Migration.MaxConcurrency` | appsettings | Parallel calls per worker (default: 8) |
| `Export.MaxUsers` | appsettings | Cap for smoke tests (0 = unlimited) |
| `Harvest.IdsPerMessage` | appsettings | User IDs per queue message (default: 20) |
| `PhoneRegistration.ThrottleDelayMs` | appsettings | Rate control (default: 400ms) |
| `Storage.AuditMode` | appsettings | `File` (default), `Table`, or `None` |
| `JitAuthentication.TestMode` | local.settings.json | Skip B2C validation (testing only) |
| `JitAuthentication.CachePrivateKey` | local.settings.json | Cache RSA key in memory |
| `JitAuthentication.TimeoutSeconds` | local.settings.json | ROPC timeout (default: 1.5) |
