# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
<#
.SYNOPSIS
    Initializes Azurite and runs the B2C export console application locally.

.DESCRIPTION
    This script:
    1. Checks if Azurite is installed
    2. Starts Azurite blob service on default port (10000)
    3. Creates required storage containers
    4. Runs the B2C export console application with local configuration

.PARAMETER ConfigFile
    Path to the configuration file (default: appsettings.local.json)

.PARAMETER VerboseLogging
    Enable verbose logging in the console application

.PARAMETER SkipAzurite
    Skip Azurite initialization (use if already running)

.EXAMPLE
    .\Start-LocalExport.ps1

.EXAMPLE
    .\Start-LocalExport.ps1 -ConfigFile "appsettings.dev.json" -VerboseLogging

.EXAMPLE
    .\Start-LocalExport.ps1 -SkipAzurite
#>

param(
    [Parameter(Mandatory = $false)]
    [string]$ConfigFile = "appsettings.local.json",

    [Parameter(Mandatory = $false)]
    [switch]$VerboseLogging,

    [Parameter(Mandatory = $false)]
    [switch]$SkipAzurite
)

$ErrorActionPreference = "Stop"

# Script directory
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$rootDir = Split-Path -Parent $scriptDir
$consoleAppDir = Join-Path $rootDir "src\B2CMigrationKit.Console"
$configPath = Join-Path $consoleAppDir $ConfigFile

# Colors for output
function Write-Success { Write-Host $args -ForegroundColor Green }
function Write-Info { Write-Host $args -ForegroundColor Cyan }
function Write-Warning { Write-Host $args -ForegroundColor Yellow }
function Write-Error { Write-Host $args -ForegroundColor Red }

# Header
Write-Host ""
Write-Host "═══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  B2C Migration Kit - Local Export Runner" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# Validate configuration file exists
if (-not (Test-Path $configPath)) {
    Write-Error "Configuration file not found: $configPath"
    Write-Info "Please create the configuration file or specify a different one with -ConfigFile parameter"
    exit 1
}

Write-Success "✓ Configuration file found: $ConfigFile"

# Auto-detect if Azurite is needed by checking the connection string
$needsAzurite = $false
if (-not $SkipAzurite) {
    try {
        $configContent = Get-Content $configPath -Raw | ConvertFrom-Json
        $connectionString = $configContent.Migration.Storage.ConnectionStringOrUri
        
        if ($connectionString -eq "UseDevelopmentStorage=true" -or 
            $connectionString -like "*127.0.0.1*" -or 
            $connectionString -like "*localhost*") {
            $needsAzurite = $true
            Write-Info "Detected local storage emulator configuration - Azurite will be started"
        }
        else {
            Write-Info "Detected cloud storage configuration - Skipping Azurite"
            $SkipAzurite = $true
        }
    }
    catch {
        Write-Warning "⚠ Could not parse config file to detect storage type - assuming Azurite is needed"
        $needsAzurite = $true
    }
}

# Check if Azurite is installed
if (-not $SkipAzurite -and $needsAzurite) {
    Write-Info "Checking Azurite installation..."

    $azuriteInstalled = $null
    try {
        $azuriteInstalled = Get-Command azurite -ErrorAction SilentlyContinue
    }
    catch {
        # Ignore error
    }

    if (-not $azuriteInstalled) {
        Write-Error "Azurite is not installed!"
        Write-Info "Install Azurite using: npm install -g azurite"
        Write-Info "Or run this script with -SkipAzurite if you're using a different storage emulator"
        exit 1
    }

    Write-Success "✓ Azurite is installed"

    # Check if Azurite is already running
    Write-Info "Checking if Azurite is already running..."
    $azuriteProcess = Get-Process -Name "azurite" -ErrorAction SilentlyContinue

    if ($azuriteProcess) {
        Write-Warning "⚠ Azurite is already running (PID: $($azuriteProcess.Id))"
        Write-Info "Using existing Azurite instance"
    }
    else {
        Write-Info "Starting Azurite..."

        # Create workspace directory for Azurite
        $azuriteWorkspace = Join-Path $rootDir ".azurite"
        if (-not (Test-Path $azuriteWorkspace)) {
            New-Item -ItemType Directory -Path $azuriteWorkspace | Out-Null
        }

        # Start Azurite in background
        try {
            # Build arguments as a single string for cmd.exe
            $azuriteCommand = "azurite --silent --location `"$azuriteWorkspace`" --blobPort 10000 --queuePort 10001"
            
            # Use cmd.exe to run azurite to avoid file association issues
            $azuriteJob = Start-Process -FilePath "cmd.exe" -ArgumentList "/c", $azuriteCommand -WindowStyle Hidden -PassThru

            # Wait for Azurite to start
            Write-Info "Waiting for Azurite to start..."
            Start-Sleep -Seconds 5

            # Verify Azurite is running
            $azuriteProcess = Get-Process -Id $azuriteJob.Id -ErrorAction SilentlyContinue
            if (-not $azuriteProcess) {
                Write-Error "Failed to start Azurite - process exited unexpectedly"
                Write-Info "Try running 'azurite' manually to see the error"
                exit 1
            }

            Write-Success "✓ Azurite started successfully (PID: $($azuriteProcess.Id))"
        }
        catch {
            Write-Error "Failed to start Azurite: $_"
            Write-Info "Make sure Azurite is properly installed: npm install -g azurite"
            exit 1
        }
    }

    # Initialize storage containers
    Write-Info "Initializing storage containers..."

    try {
        # Using Azure CLI to create containers (requires az cli)
        $azInstalled = Get-Command az -ErrorAction SilentlyContinue

        if ($azInstalled) {
            $connectionString = "UseDevelopmentStorage=true"

            # Create blob containers
            az storage container create --name "user-exports" --connection-string $connectionString --only-show-errors 2>&1 | Out-Null
            az storage container create --name "migration-errors" --connection-string $connectionString --only-show-errors 2>&1 | Out-Null

            # Create queue
            az storage queue create --name "profile-updates" --connection-string $connectionString --only-show-errors 2>&1 | Out-Null

            Write-Success "✓ Storage containers initialized"
        }
        else {
            Write-Warning "⚠ Azure CLI not found - skipping container creation"
            Write-Info "Containers will be created automatically on first use"
        }
    }
    catch {
        Write-Warning "⚠ Failed to create containers (they may already exist or will be created on first use)"
    }
}
else {
    if ($SkipAzurite) {
        Write-Info "Skipping Azurite initialization (using -SkipAzurite or cloud storage detected)"
    }
}

Write-Host ""
Write-Info "Starting B2C export..."
Write-Host ""

# Build console application arguments
$appArgs = @("export", "--config", $ConfigFile)
if ($VerboseLogging) {
    $appArgs += "--verbose"
}

# Run the console application
try {
    Push-Location $consoleAppDir

    # Build the project first
    Write-Info "Building console application..."
    dotnet build --configuration Debug --nologo --verbosity quiet

    if ($LASTEXITCODE -ne 0) {
        Write-Error "Failed to build console application"
        exit 1
    }

    Write-Success "✓ Build successful"
    Write-Host ""

    # Run the application
    dotnet run --no-build --configuration Debug -- $appArgs

    $exitCode = $LASTEXITCODE
}
finally {
    Pop-Location
}

Write-Host ""

if ($exitCode -eq 0) {
    Write-Success "═══════════════════════════════════════════════"
    Write-Success "  Export completed successfully!"
    Write-Success "═══════════════════════════════════════════════"
}
else {
    Write-Error "═══════════════════════════════════════════════"
    Write-Error "  Export failed with exit code: $exitCode"
    Write-Error "═══════════════════════════════════════════════"
}

Write-Host ""

# Cleanup instructions
if (-not $SkipAzurite -and -not $azuriteProcess) {
    Write-Info "To stop Azurite, run: Stop-Process -Name azurite"
}

exit $exitCode
