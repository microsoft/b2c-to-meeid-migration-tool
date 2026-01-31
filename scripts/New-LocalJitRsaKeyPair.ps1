# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.
<#
.SYNOPSIS
    Generates an RSA key pair locally for JIT Authentication testing.

.DESCRIPTION
    Creates RSA-2048 key pair for local development/testing.
    Outputs:
    - Private key in PEM format (for local.settings.json inline config)
    - Public key in JWK format (for reference)
    - Public key in X.509 format (for Custom Extension app registration)
    
    ⚠️ WARNING: For LOCAL TESTING ONLY
    Production should use New-JitRsaKeyPair.ps1 with Azure Key Vault.

.PARAMETER OutputPath
    Directory where key files will be saved. Default: current directory

.EXAMPLE
    .\New-LocalJitRsaKeyPair.ps1
    
    Generates keys in current directory

.EXAMPLE
    .\New-LocalJitRsaKeyPair.ps1 -OutputPath "./keys"
    
    Generates keys in ./keys directory
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$OutputPath = "."
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Yellow
Write-Host "  RSA Key Pair Generator - LOCAL TESTING MODE" -ForegroundColor Yellow
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Yellow
Write-Host ""
Write-Host "⚠️  WARNING: This generates keys LOCALLY without HSM protection" -ForegroundColor Red
Write-Host "   For PRODUCTION, use New-JitRsaKeyPair.ps1 with Key Vault" -ForegroundColor Red
Write-Host ""

# Ensure output directory exists
if (-not (Test-Path $OutputPath)) {
    New-Item -ItemType Directory -Path $OutputPath -Force | Out-Null
}

$OutputPath = Resolve-Path $OutputPath

Write-Host "Generating RSA-2048 key pair..." -ForegroundColor Cyan

# Generate RSA key pair using .NET
Add-Type -AssemblyName System.Security

$rsa = [System.Security.Cryptography.RSA]::Create(2048)

# Export private key (PKCS#8 format)
$privateKeyBytes = $rsa.ExportPkcs8PrivateKey()
$privateKeyBase64 = [Convert]::ToBase64String($privateKeyBytes)
$privateKeyPem = "-----BEGIN PRIVATE KEY-----`n"
for ($i = 0; $i -lt $privateKeyBase64.Length; $i += 64) {
    $length = [Math]::Min(64, $privateKeyBase64.Length - $i)
    $privateKeyPem += $privateKeyBase64.Substring($i, $length) + "`n"
}
$privateKeyPem += "-----END PRIVATE KEY-----"

# Export public key parameters for JWK
$publicKeyParams = $rsa.ExportParameters($false)

# Convert byte arrays to Base64Url (RFC 7515)
function ConvertTo-Base64Url {
    param([byte[]]$bytes)
    $base64 = [Convert]::ToBase64String($bytes)
    return $base64.TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

$nBase64Url = ConvertTo-Base64Url $publicKeyParams.Modulus
$eBase64Url = ConvertTo-Base64Url $publicKeyParams.Exponent

# Generate unique key ID
$kid = [Guid]::NewGuid().ToString()

# Create self-signed certificate using the SAME RSA key pair
Write-Host "Generating self-signed certificate..." -ForegroundColor Cyan

# Create certificate request using our existing RSA key
$certReq = [System.Security.Cryptography.X509Certificates.CertificateRequest]::new(
    "CN=JIT Migration Local Test",
    $rsa,
    [System.Security.Cryptography.HashAlgorithmName]::SHA256,
    [System.Security.Cryptography.RSASignaturePadding]::Pkcs1
)

# Add key usage extensions
$keyUsage = [System.Security.Cryptography.X509Certificates.X509KeyUsageExtension]::new(
    [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::KeyEncipherment -bor
    [System.Security.Cryptography.X509Certificates.X509KeyUsageFlags]::DataEncipherment,
    $false
)
$certReq.CertificateExtensions.Add($keyUsage)

# Create self-signed certificate (valid for 2 years)
$notBefore = [DateTime]::UtcNow
$notAfter = $notBefore.AddYears(2)
$cert = $certReq.CreateSelfSigned($notBefore, $notAfter)

# Export certificate to DER format (public key only)
$certBytes = $cert.Export([System.Security.Cryptography.X509Certificates.X509ContentType]::Cert)
$certBase64 = [Convert]::ToBase64String($certBytes)

# Also export just the public key (for reference)
$publicKeyBytes = $rsa.ExportSubjectPublicKeyInfo()
$publicKeyBase64 = [Convert]::ToBase64String($publicKeyBytes)

# Create JWK (JSON Web Key) for public key
$publicKeyJwk = @{
    kty = "RSA"
    use = "enc"
    kid = $kid
    n = $nBase64Url
    e = $eBase64Url
} | ConvertTo-Json -Depth 5

# Save private key
$privateKeyPath = Join-Path $OutputPath "jit-private-key.pem"
$privateKeyPem | Out-File -FilePath $privateKeyPath -Encoding ASCII -NoNewline

# Save public key (JWK)
$publicKeyJwkPath = Join-Path $OutputPath "jit-public-key.jwk.json"
$publicKeyJwk | Out-File -FilePath $publicKeyJwkPath -Encoding UTF8

# Save certificate (X.509 DER base64 for Graph API keyCredentials)
$certPath = Join-Path $OutputPath "jit-certificate.txt"
$certBase64 | Out-File -FilePath $certPath -Encoding ASCII -NoNewline

# Save public key only (for reference)
$publicKeyPath = Join-Path $OutputPath "jit-public-key-x509.txt"
$publicKeyBase64 | Out-File -FilePath $publicKeyPath -Encoding ASCII -NoNewline

Write-Host ""
Write-Host "✓ RSA key pair generated successfully!" -ForegroundColor Green
Write-Host ""
Write-Host "Files created:" -ForegroundColor Cyan
Write-Host "  Private Key (PEM):      $privateKeyPath" -ForegroundColor White
Write-Host "  Public Key (JWK):       $publicKeyJwkPath" -ForegroundColor White
Write-Host "  Certificate (X.509):    $certPath" -ForegroundColor White
Write-Host "  Public Key (X.509):     $publicKeyPath" -ForegroundColor Gray
Write-Host ""
Write-Host "Key ID (kid): $kid" -ForegroundColor Yellow
Write-Host "Certificate:  $($cert.Subject)" -ForegroundColor Gray
Write-Host "Valid:        $($cert.NotBefore.ToString('yyyy-MM-dd')) to $($cert.NotAfter.ToString('yyyy-MM-dd'))" -ForegroundColor Gray
Write-Host ""
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Next Steps" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "1. Copy PRIVATE KEY to local.settings.json:" -ForegroundColor Yellow
Write-Host "   - Open: $privateKeyPath"
Write-Host "   - Copy the ENTIRE content (including BEGIN/END lines)"
Write-Host "   - Paste into: Migration__JitAuthentication__InlineRsaPrivateKey"
Write-Host "   - Replace newlines with literal \n in JSON"
Write-Host ""
Write-Host "2. Use Manage-CustomAuthExtension.ps1 to configure Custom Extension:" -ForegroundColor Yellow
Write-Host "   - Script will automatically read jit-public-key-x509.txt"
Write-Host "   - Public key will be uploaded to Graph API"
Write-Host ""
Write-Host "   Example:" -ForegroundColor Gray
Write-Host "   .\Manage-CustomAuthExtension.ps1 -Operation Create ``" -ForegroundColor Cyan
Write-Host "       -NgrokUrl 'https://YOUR_NGROK_URL.ngrok.app' ``" -ForegroundColor Cyan
Write-Host "       -ApplyToAllApps" -ForegroundColor Cyan
Write-Host "   - Use Graph API to upload to app registration"
Write-Host "   - See: TESTING_PLAN.md Phase 4.2"
Write-Host ""
Write-Host "Key ID (kid): $kid" -ForegroundColor Magenta
Write-Host ""

# Cleanup sensitive object
$rsa.Dispose()
