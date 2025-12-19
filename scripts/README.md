# B2C Migration Kit - Scripts

This directory contains PowerShell scripts for local development, testing, and JIT migration setup.

**📖 For complete setup instructions, see the [Developer Guide](../docs/DEVELOPER_GUIDE.md)**

## Table of Contents

- [Prerequisites](#prerequisites)
- [Quick Start](#quick-start)
- [Export & Import Scripts](#export--import-scripts)
- [JIT Migration Setup](#jit-migration-setup)
  - [Generate RSA Keys](#1-generate-rsa-keys)
  - [Configure External ID](#2-configure-external-id)
  - [Switch Environments](#3-switch-environments)
- [Configuration](#configuration)
- [Troubleshooting](#troubleshooting)

---

## Prerequisites

### For Export/Import Operations

1. **.NET 8.0 SDK** - Build and run the console application
   ```powershell
   dotnet --version  # Should be 8.0+
   ```

2. **Azurite** - Azure Storage emulator for local development
   ```powershell
   npm install -g azurite
   ```

3. **Configuration** - `appsettings.local.json` with tenant credentials
   - See [Developer Guide - Configuration](../docs/DEVELOPER_GUIDE.md#configuration-guide)

### For JIT Migration Testing

4. **PowerShell 7.0+** - Modern PowerShell features
   ```powershell
   $PSVersionTable.PSVersion  # Should be 7.0+
   ```

5. **ngrok** - Expose local function to internet
   ```powershell
   choco install ngrok
   # Or download from https://ngrok.com/download
   ```

6. **Azure Function Core Tools** - Run functions locally
   ```powershell
   npm install -g azure-functions-core-tools@4
   ```

---

---

## Quick Start

**Recommended workflow:** Use the PowerShell scripts that automatically handle Azurite setup.

### Export Users from B2C
```powershell
.\scripts\Start-LocalExport.ps1
```

### Import Users to External ID
```powershell
.\scripts\Start-LocalImport.ps1
```

**✅ What these scripts do automatically:**
- Check if Azurite is installed (prompt for installation if missing)
- Auto-detect if you need Azurite based on your connection string
- Start Azurite automatically if needed (or use existing instance)
- Create required storage containers and queues
- Build and run the console application
- Display color-coded progress and status messages

---

## Export & Import Scripts

### Start-LocalExport.ps1

Exports users from Azure AD B2C to local Azurite storage.

**Usage:**
```powershell
.\Start-LocalExport.ps1 [-VerboseLogging] [-ConfigFile "config.json"]
```

**Parameters:**
- `-ConfigFile` - Configuration file path (default: `appsettings.local.json`)
- `-VerboseLogging` - Enable detailed logging
- `-SkipAzurite` - Skip Azurite initialization (use cloud storage)

**What it does:**
1. Validates configuration file exists
2. Auto-detects if local storage emulator is needed
3. Checks if Azurite is installed (prompts if missing)
4. Starts Azurite if needed
5. Creates storage containers (`user-exports`, `migration-errors`)
6. Builds the console application
7. Runs the export operation

### Start-LocalImport.ps1

Imports users from local Azurite storage to Entra External ID.

**Usage:**
```powershell
.\Start-LocalImport.ps1 [-VerboseLogging] [-ConfigFile "config.json"]
```

**Parameters:**
- `-ConfigFile` - Configuration file path (default: `appsettings.local.json`)
- `-VerboseLogging` - Enable detailed logging
- `-SkipAzurite` - Skip Azurite initialization (use cloud storage)

**What it does:**
1. Validates configuration file exists
2. Auto-detects if local storage emulator is needed
3. Checks if Azurite is installed (prompts if missing)
4. Starts Azurite if needed
5. Builds the console application
6. Runs the import operation

---

## JIT Migration Setup

Complete setup for Just-In-Time password migration during user's first login.

### 1. Generate RSA Keys

**Script:** `New-LocalJitRsaKeyPair.ps1`

Generates RSA-2048 key pair for local testing (files stored in `scripts/` directory).

**Usage:**
```powershell
.\New-LocalJitRsaKeyPair.ps1
```

**Files Generated** (automatically git-ignored):
- `jit-private-key.pem` - RSA private key (keep secret!)
- `jit-certificate.txt` - X.509 certificate (upload to Azure)
- `jit-public-key-x509.txt` - Public key in X.509 format
- `jit-public-key.jwk.json` - Public key in JWK format

**What each file is used for:**

1. **jit-private-key.pem** ⚠️ SECRET
   - Used by Azure Function to decrypt payloads from External ID
   - Add to `local.settings.json` → `Migration__JitAuthentication__InlineRsaPrivateKey`
   - Never commit or share this file

2. **jit-certificate.txt**
   - X.509 certificate in base64 format
   - Upload to Custom Extension App Registration in Azure Portal
   - Used by External ID to encrypt payloads sent to your function

3. **jit-public-key.jwk.json**
   - Public key in JSON Web Key format
   - Used by `Configure-ExternalIdJit.ps1` script
   - Safe to share (it's a public key)

**🔐 Security Notes:**
- These keys are for **LOCAL TESTING ONLY**
- For production, use Azure Key Vault with HSM-protected keys
- Never commit private keys to source control (already in `.gitignore`)

**Verify keys created:**
```powershell
Get-ChildItem .\jit-*.* | Select-Object Name, Length

# Expected output:
# Name                        Length
# ----                        ------
# jit-private-key.pem          1704
# jit-certificate.txt          1159
# jit-public-key-x509.txt       451
# jit-public-key.jwk.json       394
```

### 2. Configure External ID

**Script:** `Configure-ExternalIdJit.ps1`

Automates complete External ID configuration for JIT migration using device code flow.

**What it creates:**
1. Custom Authentication Extension App registration
2. Encryption certificate upload
3. Custom Authentication Extension (links to your Azure Function)
4. Test Client Application (for testing sign-in flows)
5. Service Principal (required for Event Listener)
6. Extension Attribute (`RequireMigration` boolean)
7. Event Listener Policy (triggers JIT on password submission)
8. User Flow (enables sign-up/sign-in with JIT)

**Usage:**
```powershell
# Basic usage
.\Configure-ExternalIdJit.ps1 `
    -TenantId "your-external-id-tenant-id" `
    -CertificatePath ".\jit-certificate.txt" `
    -FunctionUrl "https://your-function.azurewebsites.net/api/JitAuthentication" `
    -ExtensionAppObjectId "b2c-extensions-app-object-id" `
    -MigrationAttributeName "RequireMigration"

# For local testing with ngrok
.\Configure-ExternalIdJit.ps1 `
    -TenantId "your-external-id-tenant-id" `
    -CertificatePath ".\jit-certificate.txt" `
    -FunctionUrl "https://your-domain.ngrok-free.dev/api/JitAuthentication" `
    -ExtensionAppObjectId "your-b2c-extensions-app-object-id" `
    -MigrationAttributeName "RequireMigration" `
    -UseUniqueNames
```

**Parameters:**

| Parameter | Required | Description |
|-----------|----------|-------------|
| `TenantId` | Yes | External ID tenant ID |
| `CertificatePath` | Yes | Path to `jit-certificate.txt` file |
| `FunctionUrl` | Yes | Azure Function endpoint URL |
| `ExtensionAppObjectId` | Yes | b2c-extensions-app Object ID |
| `MigrationAttributeName` | No | Extension attribute name (default: "RequireMigration") |
| `UseUniqueNames` | No | Generate unique app names (useful for testing multiple configs) |

**How to find b2c-extensions-app Object ID:**
1. Azure Portal → Your External ID Tenant
2. App registrations → All applications
3. Search for: `b2c-extensions-app`
4. Copy the **Object ID** (NOT the Application ID)

**Authentication Flow:**
1. Script opens device code login (`https://microsoft.com/devicelogin`)
2. Sign in with External ID admin account
3. Grant required permissions:
   - `Application.ReadWrite.All`
   - `CustomAuthenticationExtension.ReadWrite.All`
   - `User.Read`

**Manual Steps Required:**
- **Step 2:** Grant admin consent in Azure Portal for Extension App
  - Portal → App registrations → [Extension App] → API permissions
  - Click "Grant admin consent for [Tenant]"
- **Step 5:** (Optional) Grant consent for test client app (not needed for JIT)

**Output:**
After successful completion, the script displays a configuration summary with all IDs:

```
═══════════════════════════════════════════════════════════════
  CONFIGURATION SUMMARY
═══════════════════════════════════════════════════════════════

Custom Extension App:
  → App ID: 00000000-0000-0000-0000-000000000001

Custom Authentication Extension:
  → Extension ID: 00000000-0000-0000-0000-000000000002

Test Client App:
  → App ID: 00000000-0000-0000-0000-000000000003

Event Listener:
  → Migration Property: extension_00000000000000000000000000000001_RequireMigration

User Flow:
  → Display Name: JIT Migration Flow (20251219-123721)
```

**Save these IDs** for testing and troubleshooting.

### 3. Switch Environments

**Script:** `Switch-JitEnvironment.ps1`

Toggle Custom Authentication Extension between local (ngrok) and Azure Function endpoints.

**Usage:**
```powershell
# Switch to local ngrok for development
.\Switch-JitEnvironment.ps1 -Environment Local

# Switch to Azure Function for production
.\Switch-JitEnvironment.ps1 -Environment Azure
```

**Parameters:**
- `-Environment` - Target environment (`Local` or `Azure`)

**What it does:**
- Updates Custom Authentication Extension target URL
- For Local: Uses ngrok URL from configuration
- For Azure: Uses Azure Function URL
- Validates endpoint is reachable before switching

---

---

## Configuration

### Local Development Configuration

The scripts use `appsettings.local.json` by default, pre-configured for Azurite:

```json
{
  "Migration": {
    "Storage": {
      "ConnectionStringOrUri": "UseDevelopmentStorage=true",
      "UseManagedIdentity": false
    },
    "KeyVault": null,
    "Telemetry": {
      "Enabled": false
    }
  }
}
```

**What this means:**
- ✅ **Storage**: Local Azurite emulator (no Azure Storage account needed)
- ✅ **Secrets**: Use `ClientSecret` directly in config (no Key Vault needed)
- ✅ **Telemetry**: Console logging only (no Application Insights needed)

**To run locally, you only need:**
1. Install Azurite: `npm install -g azurite`
2. Copy `appsettings.json` to `appsettings.local.json`
3. Add your B2C/External ID app registration credentials
4. Run: `.\scripts\Start-LocalExport.ps1`

### Production/Cloud Storage

To use Azure Storage instead of Azurite:

```json
{
  "Migration": {
    "Storage": {
      "ConnectionStringOrUri": "https://yourstorage.blob.core.windows.net",
      "UseManagedIdentity": true
    },
    "KeyVault": {
      "VaultUri": "https://yourkeyvault.vault.azure.net/",
      "UseManagedIdentity": true
    }
  }
}
```

The scripts will automatically detect this and skip Azurite.

**📖 See [Developer Guide - Configuration](../docs/DEVELOPER_GUIDE.md#configuration-guide) for complete setup instructions**

### Security Warning

**NEVER commit `appsettings.local.json` with real secrets to source control!**

The file is already in `.gitignore`. For production:
- Use Azure Key Vault for secrets
- Set `Migration.KeyVault.VaultUri`
- Use `ClientSecretName` instead of `ClientSecret`
- Enable Managed Identity authentication

### Azurite Storage Location

Azurite stores data in the repository root. To view data:
- Use Azure Storage Explorer (connect to local emulator)
- Or use Azure CLI: `UseDevelopmentStorage=true`

**Stopping Azurite:**
```powershell
Stop-Process -Name azurite
```

---

## Troubleshooting

**"Azurite is not installed"**
```powershell
npm install -g azurite
```

**"Configuration file not found"**
- Ensure you're in the repository root
- Or use `-ConfigFile` parameter with full path

**"Failed to start Azurite"**
- Check if port 10000/10001 is in use
- Stop manually: `Stop-Process -Name azurite`

**"Certificate not found"** (JIT setup)
- Verify path: `Test-Path ".\jit-certificate.txt"`
- Make sure you ran `New-LocalJitRsaKeyPair.ps1` first

**Build errors**
```powershell
dotnet --version  # Should be 8.0+
dotnet clean
```

**Function not called** (JIT)
- Event Listener has correct `appId` in conditions
- User Flow associated with test client app
- User has correct extension attribute set to `true`
- ngrok tunnel is active and URL matches configuration

**"B2C credential validation failed"** (JIT)
- B2C ROPC app configured correctly
- User exists in B2C with same username
- Password matches B2C password
- B2C tenant ID and policy in Function configuration

### Workflow Example

Complete local development workflow:

```powershell
# 1. Export from B2C to local storage
.\scripts\Start-LocalExport.ps1 -VerboseLogging

# 2. Inspect data (optional - use Azure Storage Explorer)

# 3. Import to External ID
.\scripts\Start-LocalImport.ps1 -VerboseLogging

# 4. Generate JIT keys
.\scripts\New-LocalJitRsaKeyPair.ps1

# 5. Configure External ID for JIT
.\scripts\Configure-ExternalIdJit.ps1 `
    -TenantId "your-tenant-id" `
    -CertificatePath ".\jit-certificate.txt" `
    -FunctionUrl "https://your-ngrok.ngrok-free.dev/api/JitAuthentication" `
    -ExtensionAppObjectId "your-extensions-app-id" `
    -UseUniqueNames

# 6. Test JIT (use Portal → User flows → Run user flow)

# 7. Stop Azurite when done
Stop-Process -Name azurite
```

---

## Additional Resources

- **[Developer Guide](../docs/DEVELOPER_GUIDE.md)** - Complete development documentation
- **[Azurite Documentation](https://learn.microsoft.com/azure/storage/common/storage-use-azurite)** - Local storage emulator
- **[Azure Storage Explorer](https://azure.microsoft.com/features/storage-explorer/)** - Inspect storage data
- **[ngrok Documentation](https://ngrok.com/docs)** - Local tunnel setup
