<#
.SYNOPSIS
    Full end-to-end deployment of the B2C Migration Kit to Azure VMs.

.DESCRIPTION
    Orchestrates the complete deployment pipeline:
      1. Deploy infrastructure via Bicep (5 VMs: 1 master + 2 user-workers + 2 phone-workers)
      2. Provision each VM: git clone → dotnet publish → copy role-appropriate example config
      VMs build the app themselves (no blob upload needed).

    Default VM roles:
      VM 1          — master        (harvest: B2C read-only)
      VM 2, VM 3    — user-worker   (worker-migrate: B2C read + EEID write)
      VM 4, VM 5    — phone-worker  (phone-registration: B2C + EEID auth methods)

.EXAMPLE
    ./Deploy-All.ps1 -ResourceGroup rg-b2c-eeid-mig-test1 -SshPublicKeyFile .\b2c-mig-deploy.pub

.EXAMPLE
    ./Deploy-All.ps1 -ResourceGroup rg-b2c-eeid-mig-test1 -SkipInfra

.EXAMPLE
    ./Deploy-All.ps1 -ResourceGroup rg-b2c-eeid-mig-test1 -WhatIf
#>
[CmdletBinding(SupportsShouldProcess)]
param(
    [Parameter(Mandatory)]
    [string]$ResourceGroup,

    [string]$Location = 'eastus2',

    [string]$StorageAccountName,

    [string]$VmSize = 'Standard_B2s',

    [string]$AdminUsername = 'azureuser',

    [string]$SshPublicKeyFile = "$HOME/.ssh/id_ed25519.pub",

    [bool]$DeployBastion = $true,

    [string]$GitRepo = '',

    [string]$GitBranch = '',

    [int]$MasterCount = 1,

    [int]$UserWorkerCount = 2,

    [int]$PhoneWorkerCount = 2,

    [switch]$SkipInfra,

    [Parameter(HelpMessage = 'Set to $false when redeploying to existing VMs to avoid customData conflict.')]
    [bool]$IncludeCustomData = $true
)

$ErrorActionPreference = 'Stop'

# Derive VmCount from role counts
$VmCount = $MasterCount + $UserWorkerCount + $PhoneWorkerCount

# Build role map: VM index (1-based) → role + example config
$vmRoles = @{}
$idx = 1
for ($m = 0; $m -lt $MasterCount; $m++) {
    $vmRoles[$idx] = @{ Role = 'master'; ExampleConfig = 'appsettings.master.example.json'; Label = "master" }
    $idx++
}
for ($u = 1; $u -le $UserWorkerCount; $u++) {
    $vmRoles[$idx] = @{ Role = 'user-worker'; ExampleConfig = 'appsettings.user-worker.example.json'; Label = "user-worker $u" }
    $idx++
}
for ($p = 1; $p -le $PhoneWorkerCount; $p++) {
    $vmRoles[$idx] = @{ Role = 'phone-worker'; ExampleConfig = 'appsettings.phone-worker.example.json'; Label = "phone-worker $p" }
    $idx++
}

# Auto-detect repo URL and branch from the local git repo if not specified
if (-not $GitRepo) {
    $GitRepo = git remote get-url origin 2>$null
    if (-not $GitRepo) {
        $GitRepo = 'https://github.com/microsoft/b2c-to-meeid-migration-tool.git'
    }
}
if (-not $GitBranch) {
    $GitBranch = git rev-parse --abbrev-ref HEAD 2>$null
    if (-not $GitBranch) {
        $GitBranch = 'main'
    }
}

. (Join-Path $PSScriptRoot "_Common.ps1")

# ─── Resolve StorageAccountName ───────────────────────────────────────────────
if (-not $StorageAccountName) {
    # Check if a storage account already exists in the resource group
    $existing = az storage account list --resource-group $ResourceGroup --query "[].name" -o tsv 2>$null
    if ($existing) {
        # Use the first existing storage account (handles single or multiple results)
        $StorageAccountName = ($existing -split "`n")[0].Trim()
        Write-Host "Reusing existing storage account: $StorageAccountName" -ForegroundColor Cyan
    }
    else {
        # No existing storage account — generate a new unique name
        $sanitizedRg = ($ResourceGroup -replace '[^a-zA-Z0-9]', '').ToLower()
        if ($sanitizedRg.Length -gt 14) { $sanitizedRg = $sanitizedRg.Substring(0, 14) }
        $suffix = -join ((48..57) + (97..122) | Get-Random -Count 6 | ForEach-Object { [char]$_ })
        $StorageAccountName = "st${sanitizedRg}${suffix}"

        $available = az storage account check-name --name $StorageAccountName --query nameAvailable -o tsv 2>$null
        if ($available -ne 'true') {
            $suffix = -join ((48..57) + (97..122) | Get-Random -Count 6 | ForEach-Object { [char]$_ })
            $StorageAccountName = "st${sanitizedRg}${suffix}"
        }

        Write-Host "Auto-generated storage account name: $StorageAccountName" -ForegroundColor Cyan
    }
}

$repoRoot   = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$infraDir   = Join-Path $repoRoot "infra"

# ─── Helpers ──────────────────────────────────────────────────────────────────

function Write-Step {
    param([int]$Number, [string]$Title)
    Write-Host ""
    Write-Host ("=" * 60) -ForegroundColor Magenta
    Write-Host "  Step ${Number}: $Title" -ForegroundColor Magenta
    Write-Host ("=" * 60) -ForegroundColor Magenta
    Write-Host ""
}

function Confirm-Continue {
    param([string]$Message)
    Write-Err $Message
    $choice = Read-Host "Continue anyway? [y/N]"
    if ($choice -notin @('y', 'Y', 'yes')) {
        Write-Err "Aborted."
        exit 1
    }
}

# ─── Preflight ────────────────────────────────────────────────────────────────

Write-Info "Verifying Azure CLI is logged in..."
$account = az account show --query "{name:name, id:id}" -o json 2>$null | ConvertFrom-Json
if ($LASTEXITCODE -ne 0) {
    Write-Err "Not logged in to Azure CLI. Run 'az login' first."
    exit 1
}
Write-Success "✓ Azure CLI: $($account.name) ($($account.id))"

# ─── Step 1: Deploy Infrastructure ───────────────────────────────────────────

Write-Step 1 "Deploy Infrastructure"

if ($SkipInfra) {
    Write-Warn "Skipping infrastructure deployment (-SkipInfra)."
}
elseif ($WhatIfPreference) {
    Write-Info "[WhatIf] Would run: az deployment sub create --location $Location --template-file infra/main.bicep"
}
else {
    # Read SSH public key
    if (-not (Test-Path $SshPublicKeyFile)) {
        Write-Err "SSH public key not found at $SshPublicKeyFile"
        Write-Err "Generate one: ssh-keygen -t ed25519 -C 'b2c-migration'"
        Write-Err "Or pass -SshPublicKeyFile <path>"
        exit 1
    }
    $sshKey = (Get-Content $SshPublicKeyFile -Raw).Trim()

    Write-Info "Deploying Bicep template (this may take 10-20 minutes)..."
    az deployment sub create `
        --location $Location `
        --template-file (Join-Path $infraDir "main.bicep") `
        --parameters `
            resourceGroupName=$ResourceGroup `
            location=$Location `
            storageAccountName=$StorageAccountName `
            vmCount=$VmCount `
            vmSize=$VmSize `
            adminUsername=$AdminUsername `
            adminSshPublicKey=$sshKey `
            deployBastion=$DeployBastion `
            includeCustomData=$IncludeCustomData `
        --name "b2c-migration-$(Get-Date -Format 'yyyyMMdd-HHmmss')"

    if ($LASTEXITCODE -ne 0) {
        Confirm-Continue "Infrastructure deployment failed."
    }
    else {
        Write-Success "✓ Infrastructure deployed."
    }
}

# ─── Step 2: Provision VMs (git clone + build on each VM) ────────────────────

Write-Step 2 "Provision Worker VMs"

Write-Info "Strategy: Each VM clones the repo from GitHub and builds locally."
Write-Info "Repo:     $GitRepo"
Write-Info "Branch:   $GitBranch"
Write-Host ""
Write-Info "VM Role Map:"
foreach ($key in ($vmRoles.Keys | Sort-Object)) {
    Write-Info "  vm-b2c-worker$key → $($vmRoles[$key].Label)"
}
Write-Host ""

$provisionedVms = 0
$failedVms = @()

for ($i = 1; $i -le $VmCount; $i++) {
    $vmName = "vm-b2c-worker$i"
    $roleInfo = $vmRoles[$i]
    $exampleConfig = $roleInfo.ExampleConfig

    Write-Info "Provisioning $vmName ($($roleInfo.Label)) ..."

    if ($WhatIfPreference) {
        Write-Info "  [WhatIf] Would run git clone + dotnet publish on $vmName via az vm run-command."
        continue
    }

    # Ensure VM is running before sending run-command
    $vmStatus = az vm get-instance-view --resource-group $ResourceGroup --name $vmName `
        --query "instanceView.statuses[1].displayStatus" -o tsv 2>$null
    if ($vmStatus -ne 'VM running') {
        Write-Warn "  $vmName is '$vmStatus' — starting it..."
        az vm start --resource-group $ResourceGroup --name $vmName 2>$null | Out-Null
    }

    # Wait until VM is running (max ~3 minutes)
    $maxWait = 36; $waited = 0
    while ($waited -lt $maxWait) {
        $vmStatus = az vm get-instance-view --resource-group $ResourceGroup --name $vmName `
            --query "instanceView.statuses[1].displayStatus" -o tsv 2>$null
        if ($vmStatus -eq 'VM running') { break }
        Start-Sleep -Seconds 5; $waited++
    }
    if ($vmStatus -ne 'VM running') {
        Write-Err "  $vmName did not start after ~3 minutes. Skipping."
        $failedVms += $vmName
        continue
    }
    Write-Success "  $vmName is running."

    # The script runs on the VM as root via run-command.
    # It installs prerequisites itself in case cloud-init used an older template.
    $scriptContent = @"
#!/bin/bash
set -euo pipefail

export HOME=/root
export DOTNET_CLI_HOME=/root

DEPLOY_DIR=/opt/b2c-migration/app
REPO_DIR=/opt/b2c-migration/repo

echo "=== Installing prerequisites ==="
if ! command -v git &>/dev/null || ! command -v dotnet &>/dev/null || ! dotnet --list-sdks 2>/dev/null | grep -q '^8\.'; then
    # Ensure Microsoft package repo is registered
    if [ ! -f /etc/apt/sources.list.d/microsoft-prod.list ]; then
        wget -q https://packages.microsoft.com/config/ubuntu/22.04/packages-microsoft-prod.deb -O /tmp/ms-prod.deb
        dpkg -i /tmp/ms-prod.deb
    fi
    apt-get update -y
    apt-get install -y dotnet-sdk-8.0 git
    echo "Prerequisites installed."
else
    echo "Prerequisites already present."
fi

mkdir -p `$DEPLOY_DIR
mkdir -p /opt/b2c-migration/telemetry
chmod 775 `$DEPLOY_DIR /opt/b2c-migration/telemetry

echo "=== Cloning repo ==="
rm -rf `$REPO_DIR
git clone --depth 1 --branch $GitBranch $GitRepo `$REPO_DIR

echo "=== Building ==="
dotnet publish `$REPO_DIR/src/B2CMigrationKit.Console/B2CMigrationKit.Console.csproj \
    --configuration Release \
    --output `$DEPLOY_DIR \
    --nologo \
    --verbosity quiet

chmod +x `$DEPLOY_DIR/B2CMigrationKit.Console 2>/dev/null || true

# Copy role-appropriate example config as starting point
EXAMPLE_CFG=`$REPO_DIR/src/B2CMigrationKit.Console/${exampleConfig}
if [ -f "`$EXAMPLE_CFG" ]; then
    cp `$EXAMPLE_CFG `$DEPLOY_DIR/appsettings.json
    echo "Example config (${exampleConfig}) copied to appsettings.json"
fi

chown -R ${AdminUsername}:${AdminUsername} `$DEPLOY_DIR /opt/b2c-migration/telemetry

echo "=== Setup complete for $vmName ==="
echo "App deployed to `$DEPLOY_DIR"
"@

    $tempScript = Join-Path ([System.IO.Path]::GetTempPath()) "setup-$vmName.sh"
    $scriptContent | Set-Content -Path $tempScript -NoNewline

    $result = az vm run-command invoke `
        --resource-group $ResourceGroup `
        --name $vmName `
        --command-id RunShellScript `
        --scripts "@$tempScript" 2>&1

    if ($LASTEXITCODE -ne 0) {
        Write-Warn "  run-command failed for $vmName (may be blocked by policy)."
        Write-Warn "  $result"
        $failedVms += $vmName
    }
    else {
        # Extract stdout/stderr from the JSON response
        try {
            $json = $result | ConvertFrom-Json
            $msg = $json.value[0].message
            # Check for real errors in stderr (ignore benign git/dpkg messages)
            $stderr = if ($msg -match '\[stderr\]\s*(.+)') { $Matches[1].Trim() } else { '' }
            $stderr = ($stderr -split "`n" | Where-Object {
                $_ -notmatch '^\s*$' -and
                $_ -notmatch 'Cloning into' -and
                $_ -notmatch 'debconf:' -and
                $_ -notmatch 'dpkg-preconfigure:'
            }) -join "`n"

            if ($msg -match 'Setup complete for') {
                Write-Success "  $vmName provisioned."
            }
            elseif ($stderr) {
                Write-Warn "  $vmName completed with errors:"
                Write-Host $msg
                $failedVms += $vmName
            }
            else {
                Write-Success "  $vmName provisioned."
            }
        }
        catch {
            Write-Success "  $vmName provisioned."
        }
        $provisionedVms++
    }

    Remove-Item $tempScript -ErrorAction SilentlyContinue
}

if (-not $WhatIfPreference) {
    if ($failedVms.Count -gt 0) {
        Write-Host ""
        Write-Warn "Some VMs could not be provisioned via run-command."
        Write-Warn "Deploy manually via Bastion for: $($failedVms -join ', ')"
        Write-Host ""
        Write-Info "Manual steps per VM:"
        Write-Info "  1. Open tunnel:  ./scripts/Connect-Worker.ps1 -WorkerIndex <N>"
        Write-Info "  2. SSH:          ssh -p 220<N> azureuser@localhost"
        Write-Info "  3. Run:          bash /opt/b2c-migration/repo/scripts/Setup-Worker.sh"
    }
}


# ─── Summary ──────────────────────────────────────────────────────────────────

Write-Host ""
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host "  Deployment Summary" -ForegroundColor Green
Write-Host ("=" * 60) -ForegroundColor Green
Write-Host ""

if ($WhatIfPreference) {
    Write-Info "[WhatIf] Dry run complete — no changes were made."
}
else {
    Write-Info "Resource Group:     $ResourceGroup"
    Write-Info "Storage Account:    $StorageAccountName"
    Write-Info "VMs Provisioned:    $provisionedVms / $VmCount"
    Write-Info "  Master:           $MasterCount  (harvest)"
    Write-Info "  User Workers:     $UserWorkerCount  (worker-migrate)"
    Write-Info "  Phone Workers:    $PhoneWorkerCount  (phone-registration)"
    if ($failedVms.Count -gt 0) {
        Write-Warn "VMs Pending:       $($failedVms -join ', ')"
    }
}

Write-Host ""
Write-Info "See docs/RUNBOOK.md for next steps (configure, validate, run)."
Write-Host ""
Write-Success "Done!"
