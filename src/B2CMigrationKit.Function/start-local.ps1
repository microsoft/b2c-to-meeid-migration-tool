param(
    [int]$Port = 7071,
    [string]$NgrokDomain = "transferable-nonglazed-trevor.ngrok-free.dev"
)

$ErrorActionPreference = "Stop"

# Get the directory where this script is located
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $scriptDir

# Colors
function Write-Success { Write-Host $args -ForegroundColor Green }
function Write-Info { Write-Host $args -ForegroundColor Cyan }
function Write-Warning { Write-Host $args -ForegroundColor Yellow }

Write-Host ""
Write-Host "═══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  JIT Authentication Function - Local Runner" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# Build
Write-Info "Building function..."
dotnet build --configuration Debug --nologo --verbosity minimal
if ($LASTEXITCODE -ne 0) {
    Write-Host "Build failed" -ForegroundColor Red
    exit 1
}
Write-Success "✓ Build successful"
Write-Host ""

# Kill any existing ngrok processes
Write-Info "Checking for existing ngrok processes..."
$existingNgrok = Get-Process ngrok -ErrorAction SilentlyContinue
if ($existingNgrok) {
    Write-Warning "Found existing ngrok process, stopping it..."
    Stop-Process -Name ngrok -Force -ErrorAction SilentlyContinue
    Start-Sleep -Seconds 2
    Write-Success "✓ Existing ngrok stopped"
}

# Start ngrok with static domain
Write-Info "Starting ngrok tunnel with static domain: $NgrokDomain"
$ngrokJob = Start-Process -FilePath "ngrok" -ArgumentList "http","$Port","--domain","$NgrokDomain" -WindowStyle Normal -PassThru

# Wait for ngrok tunnel with retries
$publicUrl = $null
$maxRetries = 10
for ($i = 1; $i -le $maxRetries; $i++) {
    Start-Sleep -Seconds 2
    try {
        $ngrokApi = Invoke-RestMethod -Uri "http://localhost:4040/api/tunnels" -Method Get -ErrorAction Stop
        if ($ngrokApi.tunnels.Count -gt 0) {
            $publicUrl = $ngrokApi.tunnels[0].public_url
            break
        }
        Write-Info "  Waiting for tunnel... (attempt $i/$maxRetries)"
    } catch {
        Write-Info "  Waiting for ngrok API... (attempt $i/$maxRetries)"
    }
}

if ($publicUrl) {
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════" -ForegroundColor Green
    Write-Success "✓ ngrok Tunnel Active (Static Domain)"
    Write-Host "═══════════════════════════════════════════════" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Function URL: " -NoNewline
    Write-Host "$publicUrl/api/JitAuthentication" -ForegroundColor Yellow
    Write-Host "  Static Domain: " -NoNewline
    Write-Host "$NgrokDomain" -ForegroundColor Yellow
    Write-Host ""
    
    # Copy to clipboard
    "$publicUrl/api/JitAuthentication" | Set-Clipboard
    Write-Success "✓ Function endpoint URL copied to clipboard!"
    Write-Host ""
    
    # Verify domain matches
    if ($publicUrl -notmatch $NgrokDomain) {
        Write-Warning "⚠️  Warning: ngrok URL doesn't match expected domain!"
        Write-Warning "   Expected: https://$NgrokDomain"
        Write-Warning "   Got:      $publicUrl"
    } else {
        Write-Success "✓ Domain verified: $NgrokDomain"
    }
    Write-Host ""
    
    Write-Info "Ready to test!"
    Write-Host "  • ngrok dashboard: " -NoNewline -ForegroundColor Gray
    Write-Host "http://localhost:4040" -ForegroundColor Cyan
    Write-Host "  • Test endpoint: " -NoNewline -ForegroundColor Gray
    Write-Host "curl $publicUrl/api/JitAuthentication" -ForegroundColor Cyan
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════" -ForegroundColor Green
    Write-Host ""
} else {
    Write-Host ""
    Write-Host "═══════════════════════════════════════════════" -ForegroundColor Red
    Write-Warning "✗ ngrok tunnel failed to start after $maxRetries attempts"
    Write-Warning "  Check ngrok window for errors, or try:"
    Write-Warning "  ngrok http $Port --domain $NgrokDomain --log stdout"
    Write-Host "═══════════════════════════════════════════════" -ForegroundColor Red
    Write-Host ""
    
    # Kill the failed ngrok process
    if (!$ngrokJob.HasExited) {
        Stop-Process -Id $ngrokJob.Id -Force -ErrorAction SilentlyContinue
    }
    exit 1
}

Write-Info "Starting Azure Function on port $Port..."
Write-Info "Using binaries from: bin\Debug\net8.0\"
Write-Warning "Press Ctrl+C to stop (ngrok will be cleaned up automatically)"
Write-Host ""

try {
    # Start func pointing to the built binaries explicitly
    func start --port $Port --script-root bin\Debug\net8.0
} finally {
    # Cleanup: kill ngrok when function stops (Ctrl+C or crash)
    Write-Host ""
    Write-Info "Cleaning up ngrok process..."
    if (!$ngrokJob.HasExited) {
        Stop-Process -Id $ngrokJob.Id -Force -ErrorAction SilentlyContinue
        Write-Success "✓ ngrok stopped"
    } else {
        Write-Info "ngrok already exited"
    }
}
