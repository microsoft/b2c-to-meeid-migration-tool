<#
.SYNOPSIS
    Opens a Bastion SSH tunnel to a worker VM.

.DESCRIPTION
    Wraps 'az network bastion tunnel' for quick SSH access to worker VMs.
    Each VM gets a unique local port (2201-2204). After running this,
    SSH in a separate terminal: ssh -p <port> azureuser@localhost

.PARAMETER WorkerIndex
    Worker number (1-4). Default: 1

.PARAMETER ResourceGroup
    Resource group name. Default: rg-b2c-eeid-mig-test1

.PARAMETER SubscriptionId
    Azure subscription ID. If not specified, uses current az account.

.EXAMPLE
    # Terminal 1: open tunnel
    ./Connect-Worker.ps1 -WorkerIndex 1

    # Terminal 2: SSH through tunnel
    ssh -p 2201 azureuser@localhost

    # On the VM: run migration
    cd /opt/b2c-migration/app
    ./B2CMigrationKit.Console worker-migrate --config appsettings.json
#>
[CmdletBinding()]
param(
    [ValidateRange(1, 16)]
    [int]$WorkerIndex = 1,

    [string]$ResourceGroup = 'rg-b2c-eeid-mig-test1',

    [string]$SshPrivateKeyFile = "$PSScriptRoot/b2c-mig-deploy",

    [string]$SubscriptionId
)

$ErrorActionPreference = 'Stop'

# Ensure the bastion CLI extension is installed
$installed = az extension list --query "[?name=='bastion'].name" -o tsv 2>$null
if (-not $installed) {
    Write-Host "Installing Azure CLI bastion extension..." -ForegroundColor Yellow
    az extension add --name bastion --yes 2>$null
}

$vmName = "vm-b2c-worker$WorkerIndex"
$localPort = 2200 + $WorkerIndex
$bastionName = 'bastion-b2c-migration'

if (-not $SubscriptionId) {
    $SubscriptionId = (az account show --query id -o tsv)
}

$vmResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Compute/virtualMachines/$vmName"

# Resolve SSH key path for display
$sshKeyDisplay = if (Test-Path $SshPrivateKeyFile) { Resolve-Path $SshPrivateKeyFile } else { $SshPrivateKeyFile }

Write-Host "Opening Bastion tunnel to $vmName on localhost:$localPort" -ForegroundColor Cyan
Write-Host "In another terminal, run:" -ForegroundColor Yellow
Write-Host "  ssh -p $localPort -i $sshKeyDisplay azureuser@localhost" -ForegroundColor Green
Write-Host ""
Write-Host "Press Ctrl+C to close the tunnel." -ForegroundColor DarkGray

az network bastion tunnel `
    --name $bastionName `
    --resource-group $ResourceGroup `
    --target-resource-id $vmResourceId `
    --resource-port 22 `
    --port $localPort
