# B2C Migration Kit - Scripts

PowerShell and Bash scripts for running bulk migrations, deploying Azure infrastructure, configuring JIT password migration, and analyzing telemetry.

**📖 For complete configuration reference, see the [Developer Guide](../docs/DEVELOPER_GUIDE.md)**

## Table of Contents

- [🏠 Local Development](#-local-development) — Setup, run migrations locally, test utilities
- [☁️ Azure Production](#️-azure-production) — Deploy VMs, configure workers, connect via Bastion
- [🔐 JIT Password Migration](#-jit-password-migration) — RSA keys, Custom Auth Extension, environment switching
- [📊 Analysis & Monitoring](#-analysis--monitoring) — Live dashboard, telemetry download, reports

---

## 🏠 Local Development

Scripts for setting up and running migrations on your local machine with Azurite.

**Prerequisites:**
1. **.NET 8.0 SDK** — `dotnet --version` (8.0+)
2. **Azurite VS Code Extension** — `ms-azuretools.vscode-azurite` (start with `Ctrl+Shift+P` → `Azurite: Start Service`)
3. **PowerShell 7.0+** — required for all `.ps1` scripts
4. **Configuration files** — copy the relevant `.example.json` and fill in your tenant credentials (see [Developer Guide](../docs/DEVELOPER_GUIDE.md#configuration-guide))

### Setup-Migration.ps1

Interactive wizard that walks through the **entire setup process** end-to-end. Best for **first-time setup** — it collects tenant info, creates app registrations, generates config files, and optionally deploys Azure infrastructure.

```powershell
# Fully interactive (recommended for first-time setup)
.\scripts\Setup-Migration.ps1

# Pre-fill values for faster setup
.\scripts\Setup-Migration.ps1 `
    -B2CTenantId "xxxxxxxx-..." -B2CTenantDomain "contosob2c.onmicrosoft.com" `
    -EeidTenantId "yyyyyyyy-..." -EeidTenantDomain "contosoeeid.onmicrosoft.com" `
    -ExtensionAppId "zzzzzzzzzzzzzzzzzzzzzzzzzzzzzzzz"

# Non-interactive (CI/automation)
.\scripts\Setup-Migration.ps1 -NonInteractive `
    -B2CTenantId "..." -B2CTenantDomain "..." `
    -EeidTenantId "..." -EeidTenantDomain "..." `
    -ExtensionAppId "..." -WorkerCount 4 -Mode Advanced -Target Local

# Dry run
.\scripts\Setup-Migration.ps1 -WhatIf
```

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-NonInteractive` | `false` | Accept defaults, fail if required values missing |
| `-B2CTenantId` | — | B2C tenant GUID |
| `-B2CTenantDomain` | — | B2C `.onmicrosoft.com` domain |
| `-EeidTenantId` | — | External ID tenant GUID |
| `-EeidTenantDomain` | — | External ID `.onmicrosoft.com` domain |
| `-ExtensionAppId` | — | Extension app ID (32 hex chars, no hyphens) |
| `-WorkerCount` | `5` | Number of parallel workers |
| `-Mode` | *(prompted)* | `Simple` (Export/Import) or `Advanced` (Harvest/Workers/Phone) |
| `-Target` | *(prompted)* | `Local` (Azurite) or `Azure` (VM deployment) |
| `-ResourceGroup` | `rg-b2c-migration` | Azure resource group (when Target=Azure) |
| `-Location` | `eastus2` | Azure region (when Target=Azure) |
| `-SecretExpiryYears` | `2` | Client secret validity |
| `-WhatIf` | `false` | Dry run |

**Wizard steps:**
1. **Tenant info** — collects and validates B2C/EEID tenant IDs, domains, extension app ID
2. **App registrations** — creates B2C (User.Read.All) + EEID (User.ReadWrite.All) apps per worker via device code auth, writes config files
3. **Migration mode** — Simple (export/import) or Advanced (queue-based workers + phone registration)
4. **Deployment target** — Local (Azurite) or Azure VMs (invokes Deploy-All.ps1)
5. **Summary** — prints everything created and the exact commands to run

The wizard detects existing config files and offers to skip already-completed steps.

### Initialize-MigrationEnvironment.ps1

Granular, idempotent setup script for creating app registrations, ensuring extension properties, and generating config files. Use this when you need **more control** than the wizard provides — e.g., adding workers to an existing setup, re-generating configs, or provisioning Azure-mode configs.

> **Tip**: `Setup-Migration.ps1` is the friendly wizard for first-time setup. `Initialize-MigrationEnvironment.ps1` is the power tool for granular control. Both create app registrations and generate configs — use whichever fits your workflow.

Supports two modes:

- **Local mode** (default): generates `appsettings.workerN.json` files for local development using `-StartWorker`/`-EndWorker`.
- **Azure mode**: activated when any role count (`-MasterCount`, `-UserWorkerCount`, `-PhoneWorkerCount`) is greater than 0. Generates role-specific config files in `azure-configs/` subdirectory.

```powershell
# Local mode: workers 1-3
.\scripts\Initialize-MigrationEnvironment.ps1 -StartWorker 1 -EndWorker 3 -Force

# Local mode: EEID only (B2C apps already exist)
.\scripts\Initialize-MigrationEnvironment.ps1 -SkipB2C -Force

# Local mode: extension props + configs only
.\scripts\Initialize-MigrationEnvironment.ps1 -SkipB2C -SkipEEID -Force

# Azure mode: 1 master + 3 user workers + 10 phone workers
.\scripts\Initialize-MigrationEnvironment.ps1 -MasterCount 1 -UserWorkerCount 3 -PhoneWorkerCount 10 -StorageAccountName stb2cmig123 -Force

# Preview only (either mode)
.\scripts\Initialize-MigrationEnvironment.ps1 -WhatIf
```

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-StartWorker` | `5` | First worker number (local mode) |
| `-EndWorker` | `8` | Last worker number (local mode) |
| `-ConfigFile` | `appsettings.worker1.json` | Source config for tenant IDs and shared settings |
| `-SecretExpiryYears` | `2` | Client secret validity period |
| `-Force` | `false` | Overwrite existing config files |
| `-SkipB2C` | `false` | Skip B2C app registration creation |
| `-SkipEEID` | `false` | Skip EEID app registration creation |
| `-MasterCount` | `0` | Number of master (harvest) workers — activates Azure mode when > 0 |
| `-UserWorkerCount` | `0` | Number of user-migrate workers (Azure mode) |
| `-PhoneWorkerCount` | `0` | Number of phone-registration workers (Azure mode) |
| `-StorageAccountName` | — | Azure storage account name (required in Azure mode) |
| `-UpnSuffix` | — | UPN suffix for user-worker Import config (e.g. `-test2`) |
| `-WhatIf` | `false` | Dry run — shows actions without executing |

**Azure mode output**: Config files are written to `src/B2CMigrationKit.Console/azure-configs/` with names like `appsettings.master1.json`, `appsettings.user-worker1.json`, `appsettings.phone-worker1.json`. These can be uploaded to VMs via `Configure-Worker.sh --config-file`.

### Validate-MigrationReadiness.ps1

Pre-flight checker — run before starting any migration to verify connectivity, permissions, and storage.

```powershell
.\scripts\Validate-MigrationReadiness.ps1                                    # default (simple mode)
.\scripts\Validate-MigrationReadiness.ps1 -Mode worker                       # validate worker mode prerequisites
.\scripts\Validate-MigrationReadiness.ps1 -ConfigFile "appsettings.worker1.json"  # custom config
```

| Check | What it validates |
|---|---|
| Config | JSON valid, tenant IDs and secrets not placeholders |
| Graph auth | OAuth2 client_credentials flow to both tenants |
| Permissions | User.Read and Directory access on each tenant |
| Extensions | Extension app and properties exist in EEID |
| Storage | Queue Storage reachable (Advanced Mode). Table Storage checked only if `AuditMode="Table"` |
| Tools | .NET SDK installed, PowerShell 7+ |

### Running Migrations Locally

> ⚠️ **Azurite must be running** before starting. Start via VS Code: `Ctrl+Shift+P` → `Azurite: Start Service`

#### Simple Mode (Export → Import)

For smaller tenants, no MFA phone migration needed.

```powershell
# Step 1: Export B2C users to local JSON files
.\scripts\Start-LocalExport.ps1

# Step 2: Import users to External ID
.\scripts\Start-LocalImport.ps1
```

**Config:** `appsettings.export-import.example.json`

#### Advanced Mode (Harvest → Workers)

For large tenants, supports MFA phone migration and parallel processing.

```powershell
# Step 1: Harvest (run once)
.\scripts\Start-LocalHarvest.ps1

# Step 2a: Worker Migrate (run N in parallel, each with different config)
.\scripts\Start-LocalWorkerMigrate.ps1 -ConfigFile appsettings.worker1.json
.\scripts\Start-LocalWorkerMigrate.ps1 -ConfigFile appsettings.worker2.json

# Step 2b: Phone Registration (run alongside step 2a)
.\scripts\Start-LocalPhoneRegistration.ps1 -ConfigFile appsettings.worker1.json
```

**Requirements:** Each worker needs a dedicated app registration for independent throttle quotas.

#### Common Parameters

| Parameter | Description |
|-----------|-------------|
| `-ConfigFile <path>` | Configuration file (defaults per script) |
| `-VerboseLogging` | Enable detailed debug output |
| `-SkipAzurite` | Skip local storage checks (for cloud) |

### Test Utilities

#### New-TestUser.ps1

Creates test users in External ID with `RequiresMigration` flag for JIT testing.

```powershell
.\scripts\New-TestUser.ps1 -Email "testuser@domain.com"             # single user
.\scripts\New-TestUser.ps1 -Prefix "testjit" -Count 10              # bulk: testjit1..10
.\scripts\New-TestUser.ps1 -Prefix "testjit" -Count 5 -WhatIf      # dry run
```

#### Manage-MigrationFlag.ps1

Queries and updates the `RequiresMigration` flag on External ID users.

```powershell
.\scripts\Manage-MigrationFlag.ps1                          # list users pending migration
.\scripts\Manage-MigrationFlag.ps1 -Filter all              # list all users
.\scripts\Manage-MigrationFlag.ps1 -Filter true -SetFlag false   # clear flag for pending users
.\scripts\Manage-MigrationFlag.ps1 -Discover                # list extension attributes
```

---

## ☁️ Azure Production

Scripts for deploying and managing the migration infrastructure on Azure VMs.

### Deploy-All.ps1

Single script that orchestrates the complete Azure VM deployment: infrastructure provisioning via Bicep, and VM setup via `az vm run-command` (git clone → dotnet publish → example config copy).

VMs build the app themselves from source — no blob upload needed.

```powershell
# Full deployment (infra + VM provisioning)
.\scripts\Deploy-All.ps1 -ResourceGroup rg-b2c-eeid-mig-test1 -SshPublicKeyFile .\scripts\b2c-mig-deploy.pub

# Re-provision VMs only (infra already deployed)
.\scripts\Deploy-All.ps1 -ResourceGroup rg-b2c-eeid-mig-test1 -SshPublicKeyFile .\scripts\b2c-mig-deploy.pub -SkipInfra

# Dry run
.\scripts\Deploy-All.ps1 -ResourceGroup rg-b2c-eeid-mig-test1 -WhatIf

# Custom worker count and location
.\scripts\Deploy-All.ps1 -ResourceGroup rg-b2c-eeid-mig-test1 -SshPublicKeyFile .\scripts\b2c-mig-deploy.pub -MasterCount 1 -UserWorkerCount 4 -PhoneWorkerCount 3 -Location westus2
```

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-ResourceGroup` | *(required)* | Target Azure resource group |
| `-Location` | `eastus2` | Azure region |
| `-StorageAccountName` | *(auto-generated)* | Storage account name (reuses existing or generates unique name) |
| `-MasterCount` | `1` | Number of master VMs (harvest) |
| `-UserWorkerCount` | `2` | Number of user-worker VMs (worker-migrate) |
| `-PhoneWorkerCount` | `2` | Number of phone-worker VMs (phone-registration) |
| `-VmSize` | `Standard_B2s` | VM SKU |
| `-AdminUsername` | `azureuser` | VM admin user |
| `-SshPublicKeyFile` | `~/.ssh/id_ed25519.pub` | Path to SSH public key |
| `-DeployBastion` | `true` | Whether to deploy Azure Bastion |
| `-GitRepo` | *(auto-detected from git remote)* | Git repo URL for VMs to clone |
| `-GitBranch` | *(auto-detected from current branch)* | Git branch to checkout on VMs |
| `-SkipInfra` | `false` | Skip Bicep deployment, only re-provision VMs |
| `-IncludeCustomData` | `true` | Include cloud-init customData in Bicep. Set to `$false` when redeploying to existing VMs to avoid conflicts |
| `-WhatIf` | `false` | Dry run — shows what would happen without making changes |

**Note:** Total VM count is automatically derived as `MasterCount + UserWorkerCount + PhoneWorkerCount` (default: 5 VMs).

**Pipeline steps:**
1. Deploy infrastructure via `az deployment sub create` with `infra/main.bicep`
2. Provision each VM via `az vm run-command invoke`:
   - Install .NET SDK 8.0 + git if not present
   - Git clone the repo (auto-detected from your local remote/branch)
   - `dotnet publish` to `/opt/b2c-migration/app/`
   - Copy role-appropriate example config as `appsettings.json`:
     - VM 1: `appsettings.master.example.json`
     - VM 2–3: `appsettings.user-worker.example.json`
     - VM 4–5: `appsettings.phone-worker.example.json`
3. After deployment, connect via Bastion and run `Configure-Worker.sh` on each VM (or edit `appsettings.json` manually)

**Why VMs clone the repo:** Each VM clones the git repository and runs `dotnet publish` locally. This eliminates the need for blob storage uploads, public endpoints for binary distribution, or complex artifact pipelines. Updates are as simple as `git pull && dotnet publish` on the VM (or re-run `Deploy-All.ps1 -SkipInfra` to re-provision all VMs at once).

**Prerequisites:** Azure CLI logged in (`az login`), SSH key pair generated, config changes committed and pushed to your repo.

### Setup-Worker.sh

Low-level script that runs **on the VM** to clone the repository and build the app. Normally invoked automatically by `Deploy-All.ps1` via `az vm run-command`, but can be run manually if provisioning fails or you need to update the app on a VM.

```bash
# Default branch (main)
bash /opt/b2c-migration/repo/scripts/Setup-Worker.sh

# Specific branch
bash /opt/b2c-migration/repo/scripts/Setup-Worker.sh my-branch
```

| Argument | Default | Description |
|----------|---------|-------------|
| `branch` | `main` | Git branch to clone |

**What it does:**
1. Clones the repo (shallow, single branch) to `/opt/b2c-migration/repo/`
2. Runs `dotnet publish` to `/opt/b2c-migration/app/`
3. Makes the console binary executable

After this, run `Configure-Worker.sh` to generate `appsettings.json`.

### Configure-Worker.sh

Script that runs **on the VM** to generate `appsettings.json`. Supports two modes:

- **Interactive** (default): prompts for each credential one by one — easier than editing JSON manually.
- **Non-interactive** (`--config-file`): copies a pre-built config file directly — ideal for automation or when configs were generated by `Initialize-MigrationEnvironment.ps1` in Azure mode.

```bash
# Interactive (prompts for everything):
bash /opt/b2c-migration/repo/scripts/Configure-Worker.sh

# Interactive with role pre-selected:
bash /opt/b2c-migration/repo/scripts/Configure-Worker.sh --role user-worker --worker-id 2
bash /opt/b2c-migration/repo/scripts/Configure-Worker.sh --role master

# Non-interactive (copy pre-built config):
bash /opt/b2c-migration/repo/scripts/Configure-Worker.sh --config-file /tmp/appsettings.user-worker1.json
```

| Option | Description |
|--------|-------------|
| `--role <master\|user-worker\|phone-worker>` | Skip role selection prompt |
| `--worker-id <N>` | Worker number (used in display only) |
| `--config-file <path>` | Copy this file as `appsettings.json` — skips all prompts |

Both modes write to `/opt/b2c-migration/app/appsettings.json` with `chmod 600` and run `validate` automatically.

### Connect-Worker.ps1

Opens a Bastion SSH tunnel to a worker VM for secure access.

```powershell
# Terminal 1: Open tunnel
.\scripts\Connect-Worker.ps1 -WorkerIndex 1

# Terminal 2: SSH through tunnel
ssh -p 2201 -i .\scripts\b2c-mig-deploy azureuser@localhost
```

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-WorkerIndex` | `1` | Worker number (1–16). Maps to port 2200+N |
| `-ResourceGroup` | `rg-b2c-eeid-mig-test1` | Resource group name |
| `-SshPrivateKeyFile` | `scripts/b2c-mig-deploy` | Path to SSH private key |

The script auto-installs the Azure CLI bastion extension if not present.

---

## 🔐 JIT Password Migration

After bulk migration (either mode), configure JIT so passwords migrate seamlessly on each user's first login.

### 1. Generate RSA Keys

```powershell
.\scripts\New-LocalJitRsaKeyPair.ps1
```

Generates four files (git-ignored):
- `jit-private-key.pem` — ⚠️ SECRET, used by the Azure Function to decrypt payloads
- `jit-certificate.txt` — upload to Custom Extension app registration
- `jit-public-key-x509.txt` — public key in X.509 format
- `jit-public-key.jwk.json` — public key in JWK format

### 2. Configure External ID

```powershell
.\scripts\Configure-ExternalIdJit.ps1 `
    -TenantId "your-external-id-tenant-id" `
    -CertificatePath ".\jit-certificate.txt" `
    -FunctionUrl "https://your-domain.ngrok-free.dev/api/JitAuthentication" `
    -MigrationPropertyId "extension_{ExtensionAppId}_RequiresMigration"
```

This script automates the full setup via device code flow:
- Creates Custom Authentication Extension app registration + encryption cert upload
- Creates the Custom Authentication Extension resource (linked to your Function URL)
- Creates a test client app, service principal, extension attribute, event listener, and user flow

| Parameter | Required | Description |
|-----------|----------|-------------|
| `TenantId` | Yes | External ID tenant ID |
| `CertificatePath` | Yes | Path to `jit-certificate.txt` |
| `FunctionUrl` | Yes | Azure Function or ngrok endpoint URL |
| `MigrationPropertyId` | No | Extension attribute ID (prompted if not provided) |
| `ExtensionAppName` | No | Display name for the Custom Auth Extension app (default: `EEID Auth Extension - JIT Migration`) |
| `ClientAppName` | No | Display name for the test client app (default: `JIT Migration Test Client`) |
| `SkipClientApp` | No | Skip creating the test client app |

**Manual step required:** Grant admin consent for the Extension App in Azure Portal after the script completes.

### 3. Switch Environments

Toggle JIT between local (ngrok) and Azure Function endpoints:

```powershell
.\scripts\Switch-JitEnvironment.ps1 -Environment Local   # ngrok
.\scripts\Switch-JitEnvironment.ps1 -Environment Azure    # production
```

### 4. Start the Function Locally

```powershell
cd src\B2CMigrationKit.Function
.\start-local.ps1    # builds, starts ngrok + function on port 7071
```

Test the JIT flow via Azure Portal → User flows → Run user flow.

---

## 📊 Analysis & Monitoring

### Watch-Migration.ps1

Live monitoring dashboard that tails JSONL telemetry files and shows running counters (users migrated, phones registered, errors, throttles). Refreshes every few seconds; press Ctrl+C for a final summary.

```powershell
.\scripts\Watch-Migration.ps1                                # default (5 workers, 3s refresh)
.\scripts\Watch-Migration.ps1 -WorkerCount 8                 # monitor 8 workers
.\scripts\Watch-Migration.ps1 -RefreshSeconds 2              # faster refresh
```

| Parameter | Default | Description |
|---|---|---|
| `WorkerCount` | 5 | Number of migrate + phone workers to monitor |
| `ConsoleDir` | `../src/B2CMigrationKit.Console` | Directory with telemetry JSONL files |
| `RefreshSeconds` | 3 | Seconds between dashboard refreshes |

### Download-Telemetry.ps1

Downloads audit and telemetry JSONL files from all worker VMs via Bastion tunnels. Run this from your local machine after migration completes — the storage account has no public endpoint, so files must be pulled from the VMs directly.

```powershell
# Download from all 5 workers (default)
.\scripts\Download-Telemetry.ps1

# Download from 3 workers to a custom directory
.\scripts\Download-Telemetry.ps1 -WorkerCount 3 -OutputDir ./my-telemetry
```

| Parameter | Default | Description |
|-----------|---------|-------------|
| `WorkerCount` | `5` | Number of worker VMs to download from |
| `ResourceGroup` | `rg-b2c-eeid-mig-test1` | Azure resource group |
| `SshPrivateKeyFile` | `./scripts/b2c-mig-deploy` | SSH private key used during deployment |
| `OutputDir` | `./telemetry-download` | Local directory for downloaded files |
| `AppDir` | `/opt/b2c-migration/app` | Remote directory containing .jsonl files |
| `AdminUsername` | `azureuser` | SSH username on the VMs |
| `SubscriptionId` | *(current)* | Azure subscription ID (uses current `az` context if not specified) |

Files are prefixed with the VM name (e.g., `vm-b2c-worker1_migration-audit.jsonl`) to avoid collisions.

### Upload-Telemetry.ps1

Uploads local telemetry files to Azure Blob Storage for archival or shared analysis.

### Analyze-Telemetry.ps1

Aggregates and analyzes JSONL telemetry files produced by migration workers.

```powershell
# Aggregate all 5 workers (default)
.\scripts\Analyze-Telemetry.ps1

# Aggregate 8 workers
.\scripts\Analyze-Telemetry.ps1 -WorkerCount 8

# Analyze a single file
.\scripts\Analyze-Telemetry.ps1 -TelemetryFile ..\src\B2CMigrationKit.Console\worker2-telemetry.jsonl
```

| Parameter | Default | Description |
|-----------|---------|-------------|
| `WorkerCount` | `5` | Number of worker file pairs to load |
| `ConsoleDir` | `../src/B2CMigrationKit.Console` | Directory containing telemetry files |
| `TelemetryFile` | — | Analyze a single file instead of aggregating |

**Report sections:**
- **Migrate Workers** — B2C fetch and EEID create latency percentiles (p50/p90/p95/p99), wall time breakdown, throughput, tail latency (>1s), 429 throttle counts
- **Phone Registration** — Outcomes (succeeded/skipped/failed), latency percentiles, failure breakdown by step and error code, throttle counts
- **Cross-Pipeline Summary** — Users migrated vs phones registered, coverage percentage

### JSONL Format

Each worker emits `worker{N}-telemetry.jsonl` and `phone-registration{N}-telemetry.jsonl` in the console app directory. Each line is a JSON object with `ts` (ISO-8601) and `name` fields:

| Event | Source | Key Fields |
|-------|--------|------------|
| `WorkerMigrate.Started` | worker | *(run boundary)* |
| `WorkerMigrate.B2CFetch` | worker | `fetchMs` |
| `WorkerMigrate.UserCreated` | worker | `eeidCreateMs`, `eeidApiMs` |
| `WorkerMigrate.BatchDone` | worker | `b2cFetchMs`, `eeidAvgMs`, `eeidMaxMs` |
| `Graph.Throttled` | both | `tenantRole` (B2C/EEID) |
| `PhoneRegistration.Started` | phone | *(run boundary)* |
| `PhoneRegistration.Success` | phone | `b2cGetPhoneMs`, `eeidRegisterMs`, `totalMs` |
| `PhoneRegistration.Skipped` | phone | `b2cGetPhoneMs` |
| `PhoneRegistration.Failed` | phone | `step`, `errorCode` |

The script only analyzes the **last run** per file (ignores events before the last `*.Started` marker).

---

## Shared Helpers

### _Common.ps1

Shared helper module dot-sourced by all scripts. Not meant to be run directly.

**Key functions:**

| Function | Description |
|----------|-------------|
| `Confirm-AzuriteRunning` | Checks Azurite ports are open |
| `Get-StorageMode` | Detects storage mode (Azurite vs Azure) from config |
| `Initialize-LocalStorage` | Creates queues, tables, containers in local storage |
| `Invoke-ConsoleApp` | Builds and runs the .NET console app |
| `Get-DeviceCodeToken` | Authenticates via device code flow for Graph API |
| `Invoke-Graph` | Executes Graph API calls with token refresh |
| `Get-GraphSpId` | Resolves a service principal ID from an app registration |
| `New-WorkerApp` | Creates app registrations with required permissions |
| `Ensure-ExtensionProperties` | Creates extension attributes on EEID ExtensionApp |
| `New-MasterConfigContent` | Generates appsettings JSON for master (harvest) role |
| `New-UserWorkerConfigContent` | Generates appsettings JSON for user-worker (migrate) role |
| `New-PhoneWorkerConfigContent` | Generates appsettings JSON for phone-worker role |
| `New-WorkerAppSettingsContent` | Generates appsettings JSON for local mode (generic worker) |
