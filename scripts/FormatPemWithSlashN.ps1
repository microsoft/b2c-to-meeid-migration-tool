# FormatPemWithSlashN.ps1 - Convert PEM key to JSON-safe format
#
# This script reads a PEM-encoded private key file and converts it to a format
# that can be safely embedded in JSON configuration files (e.g., appsettings.json).
# It replaces actual newlines with the literal string "\n" so the multi-line key
# becomes a single-line string suitable for JSON values.

# Path to the PEM file containing the private key
# To specify a different file:
# .\FormatPemWithSlashN.ps1 -PemPath "C:\path\my-private-key.pem"

param(
[Parameter(Mandatory = $false)]
[string]$PemPath = ".\jit-private-key.pem"
)

# Read the entire PEM file as a single string (preserves original line endings)
$pem = Get-Content $pemPath -Raw

# Convert line endings to JSON-safe escape sequences
# This replaces Windows (CRLF) and Unix (LF) line endings with the literal string "\n"
$escaped = $pem -replace "`r`n", "\n" -replace "`n", "\n"

# Copy the formatted string to clipboard for easy pasting
$escaped | Set-Clipboard

# Display success message
Write-Host "`n✓ Converted key copied to clipboard!" -ForegroundColor Green
Write-Host "`nPaste into: Migration__JitAuthentication__InlineRsaPrivateKey value" -ForegroundColor Cyan

# Output the escaped content to console for verification
Write-Host "`nFormatted key:`n" -ForegroundColor Yellow
Write-Host $escaped
Write-Host "`n"
