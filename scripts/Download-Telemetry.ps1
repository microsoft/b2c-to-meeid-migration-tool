<#
.SYNOPSIS
    Downloads audit and telemetry JSONL files from all worker VMs via Bastion tunnels.

.DESCRIPTION
    Opens a Bastion SSH tunnel to each worker VM, downloads all .jsonl files from
    the app directory via SCP, then closes the tunnel. Files are saved locally
    organized by worker name, ready for Analyze-Telemetry.ps1.

    Requires: Azure CLI with bastion extension, SSH key used during deployment.

.PARAMETER WorkerCount
    Number of worker VMs to download from (default: 5).

.PARAMETER ResourceGroup
    Azure resource group name.

.PARAMETER SshPrivateKeyFile
    Path to the SSH private key used during deployment.

.PARAMETER OutputDir
    Local directory to save downloaded files. Default: ./telemetry-download

.PARAMETER AppDir
    Remote directory on the VM where .jsonl files are located.

.EXAMPLE
    # Download from all 5 workers
    ./Download-Telemetry.ps1

    # Download from 3 workers to a custom directory
    ./Download-Telemetry.ps1 -WorkerCount 3 -OutputDir ./my-telemetry

    # Then analyze locally
    ./Analyze-Telemetry.ps1 -ConsoleDir ./telemetry-download
#>
[CmdletBinding()]
param(
    [int]$WorkerCount = 5,
    [string]$ResourceGroup = 'rg-b2c-eeid-mig-test1',
    [string]$SshPrivateKeyFile = "$PSScriptRoot/b2c-mig-deploy",
    [string]$OutputDir = "$PSScriptRoot/../telemetry-download",
    [string]$AppDir = '/opt/b2c-migration/app',
    [string]$AdminUsername = 'azureuser',
    [string]$SubscriptionId
)

$ErrorActionPreference = 'Stop'

# ── Validate prerequisites ────────────────────────────────────────────────────

if (-not (Test-Path $SshPrivateKeyFile)) {
    Write-Error "SSH private key not found at $SshPrivateKeyFile"
    return
}

$installed = az extension list --query "[?name=='bastion'].name" -o tsv 2>$null
if (-not $installed) {
    Write-Host "Installing Azure CLI bastion extension..." -ForegroundColor Yellow
    az extension add --name bastion --yes 2>$null
}

if (-not $SubscriptionId) {
    $SubscriptionId = (az account show --query id -o tsv)
}

# ── Prepare output directory ──────────────────────────────────────────────────

$OutputDir = [System.IO.Path]::GetFullPath($OutputDir)
if (-not (Test-Path $OutputDir)) {
    New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
}

Write-Host "Downloading telemetry from $WorkerCount VMs to: $OutputDir" -ForegroundColor Cyan
Write-Host ""

$bastionName = 'bastion-b2c-migration'
$totalFiles = 0

# ── Download from each worker ────────────────────────────────────────────────

for ($i = 1; $i -le $WorkerCount; $i++) {
    $vmName = "vm-b2c-worker$i"
    $localPort = 2200 + $i
    $vmResourceId = "/subscriptions/$SubscriptionId/resourceGroups/$ResourceGroup/providers/Microsoft.Compute/virtualMachines/$vmName"

    Write-Host "[$vmName] Opening Bastion tunnel on port $localPort..." -ForegroundColor Yellow

    # Start tunnel in background
    $tunnelJob = Start-Job -ScriptBlock {
        param($bastionName, $rg, $vmResourceId, $localPort)
        az network bastion tunnel `
            --name $bastionName `
            --resource-group $rg `
            --target-resource-id $vmResourceId `
            --resource-port 22 `
            --port $localPort 2>&1
    } -ArgumentList $bastionName, $ResourceGroup, $vmResourceId, $localPort

    # Wait for tunnel to be ready
    Start-Sleep -Seconds 5

    try {
        # List remote .jsonl files
        $sshOpts = @('-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=/dev/null', '-o', 'LogLevel=ERROR')
        $remoteFiles = ssh @sshOpts -p $localPort -i $SshPrivateKeyFile "$AdminUsername@localhost" `
            "ls $AppDir/*.jsonl 2>/dev/null" 2>$null

        if (-not $remoteFiles) {
            Write-Host "  [$vmName] No .jsonl files found — skipping" -ForegroundColor DarkGray
            continue
        }

        $fileList = $remoteFiles -split "`n" | Where-Object { $_.Trim() }
        Write-Host "  [$vmName] Found $($fileList.Count) file(s)" -ForegroundColor Green

        foreach ($remoteFile in $fileList) {
            $fileName = Split-Path $remoteFile -Leaf
            # Prefix with worker name to avoid collisions
            $localFile = Join-Path $OutputDir "${vmName}_${fileName}"

            Write-Host "    → $fileName" -ForegroundColor White -NoNewline
            scp @sshOpts -P $localPort -i $SshPrivateKeyFile `
                "${AdminUsername}@localhost:${remoteFile}" $localFile 2>$null

            if (Test-Path $localFile) {
                $size = [math]::Round((Get-Item $localFile).Length / 1KB, 1)
                Write-Host " ($size KB)" -ForegroundColor DarkGray
                $totalFiles++
            } else {
                Write-Host " FAILED" -ForegroundColor Red
            }
        }
    }
    finally {
        # Close tunnel
        Stop-Job $tunnelJob -ErrorAction SilentlyContinue
        Remove-Job $tunnelJob -Force -ErrorAction SilentlyContinue
        Write-Host "  [$vmName] Tunnel closed" -ForegroundColor DarkGray
    }

    Write-Host ""
}

# ── Summary ───────────────────────────────────────────────────────────────────

Write-Host "Done. Downloaded $totalFiles file(s) to: $OutputDir" -ForegroundColor Cyan
Write-Host ""
Write-Host "Next steps:" -ForegroundColor Yellow
Write-Host "  # Analyze results" -ForegroundColor Green
Write-Host "  ./Analyze-Telemetry.ps1 -ConsoleDir '$OutputDir'" -ForegroundColor Green
