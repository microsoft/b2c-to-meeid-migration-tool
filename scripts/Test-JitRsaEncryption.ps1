# Test-JitRsaEncryption.ps1
<#
.SYNOPSIS
    Tests RSA encryption/decryption using JIT certificate and private key.

.DESCRIPTION
    Encrypts a random string with the public key (from certificate)
    and decrypts it with the private key to verify the key pair works.

.PARAMETER CertificatePath
    Path to jit-certificate.txt file (public key)

.PARAMETER PrivateKeyPath
    Path to jit-private-key.pem file (private key)

.PARAMETER TestString
    String to encrypt/decrypt. If not provided, generates a random string.

.EXAMPLE
    .\Test-JitRsaEncryption.ps1

.EXAMPLE
    .\Test-JitRsaEncryption.ps1 -TestString "MySecretPassword123!"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $false)]
    [string]$CertificatePath = ".\jit-certificate.txt",

    [Parameter(Mandatory = $false)]
    [string]$PrivateKeyPath = ".\jit-private-key.pem",

    [Parameter(Mandatory = $false)]
    [string]$TestString
)

$ErrorActionPreference = "Stop"

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  RSA Encryption/Decryption Test" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""

# Generate random test string if not provided
if (-not $TestString) {
    $TestString = "TestPassword_" + [Guid]::NewGuid().ToString().Substring(0, 8)
    Write-Host "Generated random test string" -ForegroundColor Gray
}

Write-Host "Test String: " -NoNewline -ForegroundColor Cyan
Write-Host $TestString -ForegroundColor Yellow
Write-Host ""

# ============================================================================
# Load Certificate (Public Key)
# ============================================================================

Write-Host "Loading public key from certificate..." -ForegroundColor Cyan

if (-not (Test-Path $CertificatePath)) {
    Write-Host "✗ Certificate file not found: $CertificatePath" -ForegroundColor Red
    exit 1
}

try {
    # Read certificate base64
    $certBase64 = Get-Content $CertificatePath -Raw
    $certBytes = [Convert]::FromBase64String($certBase64)
    
    # Load certificate
    $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new($certBytes)
    
    Write-Host "✓ Certificate loaded" -ForegroundColor Green
    Write-Host "  Subject: $($cert.Subject)" -ForegroundColor Gray
    Write-Host "  Valid: $($cert.NotBefore.ToString('yyyy-MM-dd')) to $($cert.NotAfter.ToString('yyyy-MM-dd'))" -ForegroundColor Gray
    
    # Get RSA public key from certificate
    $rsaPublic = $cert.PublicKey.Key
}
catch {
    Write-Host "✗ Failed to load certificate: $_" -ForegroundColor Red
    exit 1
}

# ============================================================================
# Load Private Key
# ============================================================================

Write-Host ""
Write-Host "Loading private key from PEM file..." -ForegroundColor Cyan

if (-not (Test-Path $PrivateKeyPath)) {
    Write-Host "✗ Private key file not found: $PrivateKeyPath" -ForegroundColor Red
    exit 1
}

try {
    # Read PEM file
    $pemContent = Get-Content $PrivateKeyPath -Raw
    
    # Remove PEM headers/footers and whitespace
    $pemContent = $pemContent -replace "-----BEGIN PRIVATE KEY-----", ""
    $pemContent = $pemContent -replace "-----END PRIVATE KEY-----", ""
    $pemContent = $pemContent -replace "\s+", ""
    
    # Decode base64
    $privateKeyBytes = [Convert]::FromBase64String($pemContent)
    
    # Import PKCS#8 private key
    $rsaPrivate = [System.Security.Cryptography.RSA]::Create()
    $rsaPrivate.ImportPkcs8PrivateKey($privateKeyBytes, [ref]$null)
    
    Write-Host "✓ Private key loaded" -ForegroundColor Green
    Write-Host "  Key Size: $($rsaPrivate.KeySize) bits" -ForegroundColor Gray
}
catch {
    Write-Host "✗ Failed to load private key: $_" -ForegroundColor Red
    exit 1
}

# ============================================================================
# Encrypt with Public Key
# ============================================================================

Write-Host ""
Write-Host "Encrypting with public key..." -ForegroundColor Cyan

try {
    # Convert string to bytes
    $plainBytes = [System.Text.Encoding]::UTF8.GetBytes($TestString)
    
    # Encrypt using RSA-OAEP with SHA-256
    $encryptedBytes = $rsaPublic.Encrypt($plainBytes, [System.Security.Cryptography.RSAEncryptionPadding]::OaepSHA256)
    
    # Convert to base64 for display
    $encryptedBase64 = [Convert]::ToBase64String($encryptedBytes)
    
    Write-Host "✓ Encryption successful" -ForegroundColor Green
    Write-Host "  Encrypted (base64): $($encryptedBase64.Substring(0, [Math]::Min(60, $encryptedBase64.Length)))..." -ForegroundColor Gray
    Write-Host "  Size: $($encryptedBytes.Length) bytes" -ForegroundColor Gray
}
catch {
    Write-Host "✗ Encryption failed: $_" -ForegroundColor Red
    exit 1
}

# ============================================================================
# Decrypt with Private Key
# ============================================================================

Write-Host ""
Write-Host "Decrypting with private key..." -ForegroundColor Cyan

try {
    # Decrypt using RSA-OAEP with SHA-256
    $decryptedBytes = $rsaPrivate.Decrypt($encryptedBytes, [System.Security.Cryptography.RSAEncryptionPadding]::OaepSHA256)
    
    # Convert bytes back to string
    $decryptedString = [System.Text.Encoding]::UTF8.GetString($decryptedBytes)
    
    Write-Host "✓ Decryption successful" -ForegroundColor Green
    Write-Host "  Decrypted: " -NoNewline -ForegroundColor Gray
    Write-Host $decryptedString -ForegroundColor Yellow
}
catch {
    Write-Host "✗ Decryption failed: $_" -ForegroundColor Red
    exit 1
}

# ============================================================================
# Verify
# ============================================================================

Write-Host ""
Write-Host "Verifying..." -ForegroundColor Cyan

if ($TestString -eq $decryptedString) {
    Write-Host "✓ SUCCESS! Original and decrypted strings match!" -ForegroundColor Green
    Write-Host ""
    Write-Host "  Original:  $TestString" -ForegroundColor White
    Write-Host "  Decrypted: $decryptedString" -ForegroundColor White
    Write-Host ""
    Write-Host "✓ RSA key pair is working correctly!" -ForegroundColor Green
} else {
    Write-Host "✗ FAILURE! Strings do not match!" -ForegroundColor Red
    Write-Host "  Original:  $TestString" -ForegroundColor White
    Write-Host "  Decrypted: $decryptedString" -ForegroundColor White
    exit 1
}

Write-Host ""
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host "  Test Summary" -ForegroundColor Cyan
Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host ""
Write-Host "Certificate:  $CertificatePath" -ForegroundColor Gray
Write-Host "Private Key:  $PrivateKeyPath" -ForegroundColor Gray
Write-Host "Key Size:     $($rsaPrivate.KeySize) bits" -ForegroundColor Gray
Write-Host "Padding:      OAEP-SHA256" -ForegroundColor Gray
Write-Host "Test String:  $TestString" -ForegroundColor Gray
Write-Host "Status:       " -NoNewline -ForegroundColor Gray
Write-Host "PASSED ✓" -ForegroundColor Green
Write-Host ""

# Cleanup
$rsaPublic.Dispose()
$rsaPrivate.Dispose()
