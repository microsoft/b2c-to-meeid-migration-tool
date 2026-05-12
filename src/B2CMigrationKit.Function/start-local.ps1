param(
    [int]$Port = 7071
)

$ErrorActionPreference = "Stop"

# Get the directory where this script is located
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptDir

# Colors
function Write-Success { Write-Host $args -ForegroundColor Green }
function Write-Info    { Write-Host $args -ForegroundColor Cyan }
function Write-Warning { Write-Host $args -ForegroundColor Yellow }

Write-Host ""
Write-Host "═══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  JIT Authentication Function - Local Runner" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# ─── Build ────────────────────────────────────────────────────────────────────
Write-Info "Building function..."
dotnet build --configuration Debug --nologo --verbosity minimal
if ($LASTEXITCODE -ne 0) {
    Write-Host "Build failed" -ForegroundColor Red
    exit 1
}
Write-Success "✓ Build successful"
Write-Host ""

# ─── Public URL Setup ─────────────────────────────────────────────────────────
Write-Host "═══════════════════════════════════════════════" -ForegroundColor Yellow
Write-Warning "  TUNNEL SETUP (for B2C / External ID callback)"
Write-Host "═══════════════════════════════════════════════" -ForegroundColor Yellow
Write-Host ""
Write-Host "  After the function starts, expose port $Port publicly:" -ForegroundColor Gray
Write-Host ""
Write-Host "  VS Code Port Forwarding:" -ForegroundColor Cyan
Write-Host "    1. Ctrl+Shift+P → 'Ports: Forward a Port' → $Port" -ForegroundColor Gray
Write-Host "    2. Right-click the port → 'Port Visibility' → 'Public'" -ForegroundColor Gray
Write-Host "    3. Copy the Forwarded Address from the Ports panel" -ForegroundColor Gray
Write-Host ""
Write-Host "  Endpoints once forwarded:" -ForegroundColor Cyan
Write-Host "    JIT:           <forwarded-url>/api/JitAuthentication" -ForegroundColor Yellow
Write-Host "    API Connector: <forwarded-url>/api/ApiConnectorTest" -ForegroundColor Yellow
Write-Host ""
Write-Host "═══════════════════════════════════════════════" -ForegroundColor Yellow
Write-Host ""

Write-Info "Starting Azure Function on port $Port..."
Write-Warning "Press Ctrl+C to stop"
Write-Host ""

func start --port $Port --script-root bin\Debug\net8.0
.\scripts\Export-B2CApps.ps1 -TenantId "SliderInc.onmicrosoft.com" -OutputFile ".\app-migration-export.json"