# Infrastructure Guide

## Prerequisites

- Azure subscription with **Contributor** access
- SSH key pair for VM access: `ssh-keygen -t ed25519 -f scripts/b2c-mig-deploy -C "b2c-migration"`
- Azure CLI (`az`) installed and logged in (`az login`)
- PowerShell 7+

## Architecture

Deploy-All.ps1 creates the following resources:

- **Resource Group** with VNet, NAT Gateway, NSGs
- **Worker VMs** (Ubuntu 22.04, configurable count 1–16) with managed identity
- **Storage Account** with Queue, Blob, and Table Storage (private endpoints)
- **Key Vault** for secure configuration management (Deploy-All.ps1 copies example configs as starting point)
- **Bastion** for secure SSH access (no public IPs on VMs)

VMs clone the repo from GitHub, build the .NET app locally, and copy the example config as a starting point.

## Quick Start

```powershell
# Full deployment (infra + VM provisioning)
./scripts/Deploy-All.ps1 -ResourceGroup rg-b2c-eeid-mig-test1 -SshPublicKeyFile ./scripts/b2c-mig-deploy.pub

# Re-provision VMs only (infra already exists)
./scripts/Deploy-All.ps1 -ResourceGroup rg-b2c-eeid-mig-test1 -SshPublicKeyFile ./scripts/b2c-mig-deploy.pub -SkipInfra
```

The script auto-detects your Git remote URL and current branch. Override with `-GitRepo` and `-GitBranch` if needed.

## Deploy-All.ps1 Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `-ResourceGroup` | *(required)* | Target Azure resource group |
| `-Location` | `eastus2` | Azure region |
| `-StorageAccountName` | *(auto-generated)* | Storage account name (reuses existing or generates unique name) |
| `-VmSize` | `Standard_B2s` | VM SKU |
| `-AdminUsername` | `azureuser` | VM admin user |
| `-SshPublicKeyFile` | `~/.ssh/id_ed25519.pub` | Path to SSH public key |
| `-DeployBastion` | `true` | Whether to deploy Azure Bastion |
| `-GitRepo` | *(auto-detected)* | Git repo URL for VMs to clone |
| `-GitBranch` | *(auto-detected)* | Git branch to checkout on VMs |
| `-MasterCount` | `1` | Number of master VMs (harvest) |
| `-UserWorkerCount` | `2` | Number of user-worker VMs (worker-migrate) |
| `-PhoneWorkerCount` | `2` | Number of phone-worker VMs (phone-registration) |
| `-SkipInfra` | `false` | Skip Bicep deployment, only re-provision VMs |

**Note:** Total VM count is automatically derived as `MasterCount + UserWorkerCount + PhoneWorkerCount` (default: 5 VMs).

## Pipeline Steps

1. **Deploy infrastructure** via `az deployment sub create` (Bicep modules: network, storage, vm, keyvault, bastion)
2. **Provision each VM** via `az vm run-command invoke`:
   - Install .NET SDK 8.0 + git (if not present)
   - Clone the repo from GitHub
   - `dotnet publish` the console app to `/opt/b2c-migration/app/`
   - Copy role-appropriate example config as `appsettings.json`:
     - VM 1: `appsettings.master.example.json` (harvest)
     - VM 2–3: `appsettings.user-worker.example.json` (worker-migrate)
     - VM 4–5: `appsettings.phone-worker.example.json` (phone-registration)

## Connect via Bastion

SSH to VMs through Azure Bastion tunnel (no public IPs):

```powershell
# Terminal 1: open tunnel to worker 1 (port 2201)
./scripts/Connect-Worker.ps1 -WorkerIndex 1

# Terminal 2: SSH through tunnel
ssh -p 2201 -i ./scripts/b2c-mig-deploy azureuser@localhost
```

Each VM maps to port `2200 + WorkerIndex` (2201, 2202, 2203, 2204, 2205, ...).

## VM Role Map (Default)

| VM | Index | Role | Command | B2C Permission | EEID Permission |
|----|-------|------|---------|---------------|----------------|
| vm-b2c-worker1 | 1 | master | `harvest` | `User.Read.All` | *not needed* |
| vm-b2c-worker2 | 2 | user-worker | `worker-migrate` | `User.Read.All` | `User.ReadWrite.All` |
| vm-b2c-worker3 | 3 | user-worker | `worker-migrate` | `User.Read.All` | `User.ReadWrite.All` |
| vm-b2c-worker4 | 4 | phone-worker | `phone-registration` | `UserAuthenticationMethod.Read.All` | `UserAuthenticationMethod.ReadWrite.All` |
| vm-b2c-worker5 | 5 | phone-worker | `phone-registration` | `UserAuthenticationMethod.Read.All` | `UserAuthenticationMethod.ReadWrite.All` |

## Configure Workers

After connecting via SSH, edit the config with your actual tenant credentials and secrets:

```bash
nano /opt/b2c-migration/app/appsettings.json
```

The example config is already in place with placeholder values. Fill in:
- B2C tenant ID, domain, and app registration credentials
- External ID tenant ID, domain, and app registration credentials
- Storage account connection settings (VMs use managed identity)

**Important**: Each worker needs a **dedicated app registration** on a dedicated IP for independent Graph API throttle quotas.

## Run Migration

On the master VM (VM 1):

```bash
cd /opt/b2c-migration/app

# Step 1: Harvest (master only — populates the queue)
./B2CMigrationKit.Console harvest --config appsettings.json
```

On each user-worker VM (VM 2, VM 3):

```bash
cd /opt/b2c-migration/app

# Step 2: Worker migrate (run on all user-workers in parallel)
./B2CMigrationKit.Console worker-migrate --config appsettings.json
```

On each phone-worker VM (VM 4, VM 5), after worker-migrate completes:

```bash
cd /opt/b2c-migration/app

# Step 3: Phone registration (run on all phone-workers in parallel)
./B2CMigrationKit.Console phone-registration --config appsettings.json
```

## Monitor

```powershell
.\scripts\Watch-Migration.ps1 -WorkerCount 5 -RefreshSeconds 3
```

## Teardown

```bash
# Stop VMs (keeps disks, $0 compute)
for i in 1 2 3 4 5; do
  az vm deallocate -g rg-b2c-eeid-mig-test1 -n vm-b2c-worker$i --no-wait
done

# Stop Bastion
az network bastion delete -g rg-b2c-eeid-mig-test1 -n bastion-b2c-migration

# Full cleanup (deletes everything)
az group delete -n rg-b2c-eeid-mig-test1 --yes --no-wait
```

## Troubleshooting

| Problem | Cause | Fix |
|---------|-------|-----|
| `403 Insufficient privileges` on Graph | App registration missing permissions | Grant `User.ReadWrite.All` (EEID) / `User.Read.All` (B2C); admin consent required. `Directory.ReadWrite.All` is NOT needed. Run `Validate-MigrationReadiness.ps1` to verify |
| `AuthenticationFailedException` | Wrong tenant ID or expired secret | Check `appsettings.json` credentials; rotate client secret in Entra |
| Bastion tunnel hangs | NSG blocking port 22, or Bastion not running | Verify NSG allows SSH from Bastion subnet; check `az network bastion show` |
| `run-command` times out | Azure policy blocks RunCommand extension | Deploy manually via Bastion (step 5) using `Setup-Worker.sh` |
| `QueueNotFound` / `TableNotFound` | Storage containers not created | Run `Validate-MigrationReadiness.ps1 -Mode worker`; or create manually: `az storage queue create` |
| Throttling (429 responses) | Too many workers hitting Graph simultaneously | Reduce worker count or increase `ThrottleDelayMs` in config |
| Phone registration failures | Temporary Auth Session API limits | Retry with fewer concurrent workers; check telemetry for specific error codes |
| VM can't reach storage | Private Endpoint DNS not resolving | Verify Private DNS Zone linked to VNet; `nslookup <account>.queue.core.windows.net` from VM |
| Telemetry files empty | App crashed on start | SSH into VM, check `journalctl` or `~/.b2c-migration/logs/` |

## Architecture

See [Architecture Guide § 9](../docs/ARCHITECTURE_GUIDE.md#9-deployment--operations) for diagrams and design decisions.
