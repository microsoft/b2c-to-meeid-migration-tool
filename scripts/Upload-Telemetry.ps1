<#
.SYNOPSIS
    Uploads local JSONL telemetry files to Azure Blob Storage using Managed Identity.

.DESCRIPTION
    After a migration run completes, this script uploads all .jsonl files from the
    local telemetry directory to the 'telemetry' blob container. Files are organized
    by VM hostname and timestamp.

    Uses DefaultAzureCredential (Managed Identity on VMs, az login locally).
    No App Insights or Azure Monitor dependency — just JSONL → Blob.

.PARAMETER TelemetryPath
    Local directory containing .jsonl files. Default: /opt/b2c-migration/telemetry

.PARAMETER StorageAccountName
    Target storage account name.

.PARAMETER ContainerName
    Blob container name. Default: telemetry

.EXAMPLE
    ./Upload-Telemetry.ps1 -StorageAccountName stb2cmig123
#>
[CmdletBinding()]
param(
    [string]$TelemetryPath = '/opt/b2c-migration/telemetry',
    [Parameter(Mandatory)]
    [string]$StorageAccountName,
    [string]$ContainerName = 'telemetry'
)

$ErrorActionPreference = 'Stop'

$hostname = hostname
$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$blobPrefix = "$hostname/$timestamp"

$files = Get-ChildItem -Path $TelemetryPath -Filter '*.jsonl' -ErrorAction SilentlyContinue
if (-not $files) {
    Write-Host "No .jsonl files found in $TelemetryPath — nothing to upload."
    return
}

Write-Host "Uploading $($files.Count) telemetry file(s) to $StorageAccountName/$ContainerName/$blobPrefix/"

foreach ($file in $files) {
    $blobName = "$blobPrefix/$($file.Name)"
    Write-Host "  → $blobName ($([math]::Round($file.Length / 1KB, 1)) KB)"

    # Uses Managed Identity (DefaultAzureCredential) — no keys needed.
    az storage blob upload `
        --account-name $StorageAccountName `
        --container-name $ContainerName `
        --name $blobName `
        --file $file.FullName `
        --auth-mode login `
        --overwrite `
        --only-show-errors

    if ($LASTEXITCODE -ne 0) {
        Write-Warning "Failed to upload $($file.Name)"
    }
}

Write-Host "`nTelemetry upload complete. Browse at:"
Write-Host "  https://$StorageAccountName.blob.core.windows.net/$ContainerName/$blobPrefix/"
