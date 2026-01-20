# Test-JIT-Function.ps1 - Test JIT Authentication Function locally

# Developer Guide: Step 5: Test JIT Flow: Test with HTTP Client:

# Configuration
$ngrokUrl = "https://96dcf877ef56.ngrok-free.app"  # Change to your actual ngrok domain
$endpoint = "$ngrokUrl/api/JitAuthentication"

# Test payload matching External ID Custom Authentication Extension format
$payload = @{
    type = "customAuthenticationExtension"
    data = @{
        authenticationContext = @{
            correlationId = "test-12345"
            user = @{
                id = "user-object-id-from-external-id"
                userPrincipalName = "testuser@yourdomain.com"
            }
        }
        passwordContext = @{
            userPassword = "RealB2CPassword123!"
            nonce = "1234567890"
        }
    }
}

Write-Host ""
Write-Host "═══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Testing JIT Authentication Function" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "Endpoint: " -NoNewline
Write-Host $endpoint -ForegroundColor Yellow
Write-Host "User:     " -NoNewline
Write-Host $payload.data.authenticationContext.user.userPrincipalName -ForegroundColor Yellow
Write-Host ""

try {
    # Send POST request
    $response = Invoke-RestMethod -Uri $endpoint `
        -Method Post `
        -Body ($payload | ConvertTo-Json -Depth 10) `
        -ContentType "application/json" `
        -TimeoutSec 30

    Write-Host "═══════════════════════════════════════════════" -ForegroundColor Green
    Write-Host "  ✓ SUCCESS - Response Received" -ForegroundColor Green
    Write-Host "═══════════════════════════════════════════════" -ForegroundColor Green
    Write-Host ""
    Write-Host "Response:" -ForegroundColor Cyan
    $response | ConvertTo-Json -Depth 10 | Write-Host -ForegroundColor White
    Write-Host ""
}
catch {
    Write-Host "═══════════════════════════════════════════════" -ForegroundColor Red
    Write-Host "  ✗ ERROR - Request Failed" -ForegroundColor Red
    Write-Host "═══════════════════════════════════════════════" -ForegroundColor Red
    Write-Host ""
    Write-Host "Error Message:" -ForegroundColor Yellow
    Write-Host $_.Exception.Message -ForegroundColor Red
    Write-Host ""
    
    if ($_.Exception.Response) {
        Write-Host "Status Code:" -ForegroundColor Yellow
        Write-Host $_.Exception.Response.StatusCode -ForegroundColor Red
    }
}
