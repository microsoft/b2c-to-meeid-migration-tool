param(
    [int]$Port = 7071
)

$ErrorActionPreference = "Stop"

# Get the directory where this script is located
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptDir

# Colors
function Write-Success { Write-Host $args -ForegroundColor Green }
function Write-Info { Write-Host $args -ForegroundColor Cyan }
function Write-Warn { Write-Host $args -ForegroundColor Yellow }

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
Write-Host "  TUNNEL SETUP (for B2C / External ID callback)" -ForegroundColor Yellow
Write-Host "═══════════════════════════════════════════════" -ForegroundColor Yellow
Write-Host ""
Write-Info "The function will start on port $Port."
Write-Info "To expose it publicly (required for CAE callbacks):"
Write-Host ""
Write-Host "  Option 1 - VS Code Port Forwarding (recommended):" -ForegroundColor White
Write-Host "    1. Open VS Code 'Ports' panel (Ctrl+Shift+P → 'Ports: Focus')" -ForegroundColor Gray
Write-Host "    2. Forward port $Port" -ForegroundColor Gray
Write-Host "    3. Right-click → Visibility → Public" -ForegroundColor Gray
Write-Host "    4. Copy the forwarded URL" -ForegroundColor Gray
Write-Host ""
Write-Host "  Option 2 - CLI devtunnel:" -ForegroundColor White
Write-Host "    devtunnel host --port-numbers $Port --allow-anonymous" -ForegroundColor Gray
Write-Host ""
Write-Host "  Endpoints once forwarded:" -ForegroundColor Cyan
Write-Host "    JIT:           <forwarded-url>/api/JitAuthentication" -ForegroundColor Yellow
Write-Host "    API Connector: <forwarded-url>/api/ApiConnectorTest" -ForegroundColor Yellow
Write-Host ""
Write-Warn "After exposing, update the CAE targetUrl if the URL changed:"
Write-Host "    Switch-JitEnvironment.ps1 -Environment Local -Url <your-tunnel-url>/api/JitAuthentication" -ForegroundColor Gray
Write-Host ""
Write-Host "═══════════════════════════════════════════════" -ForegroundColor Green
Write-Host ""

# Start function
Write-Info "Starting Azure Function on port $Port..."
Write-Warn "Press Ctrl+C to stop"
Write-Host ""

func start --port $Port --script-root bin\Debug\net8.0
