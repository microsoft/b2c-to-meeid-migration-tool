// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
using B2CMigrationKit.Core.Abstractions;
using Microsoft.Extensions.Logging;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace B2CMigrationKit.Core.Services.Infrastructure;

/// <summary>
/// Manages RSA public key export and validation for JIT authentication.
/// RSA key pairs should be generated in Azure Key Vault for production use.
/// This service helps export public keys and provides local key generation for testing only.
/// </summary>
public class RsaKeyManager : IRsaKeyManager
{
    private readonly ILogger<RsaKeyManager> _logger;

    public RsaKeyManager(ILogger<RsaKeyManager> logger)
    {
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
    }

    public RSA GenerateKeyPairForTesting(int keySizeInBits = 2048)
    {
        if (keySizeInBits != 2048 && keySizeInBits != 4096)
        {
            throw new ArgumentException("Key size must be 2048 or 4096 bits", nameof(keySizeInBits));
        }

        _logger.LogWarning("Generating RSA key pair locally - FOR TESTING ONLY. Use Azure Key Vault for production.");
        _logger.LogInformation("Generating RSA key pair with {KeySize} bits", keySizeInBits);

        var rsa = RSA.Create(keySizeInBits);

        _logger.LogInformation("RSA key pair generated successfully");

        return rsa;
    }

    public string ExportPublicKeyPem(RSA rsa)
    {
        if (rsa == null)
            throw new ArgumentNullException(nameof(rsa));

        _logger.LogDebug("Exporting public key as PEM");

        var publicKeyPem = rsa.ExportSubjectPublicKeyInfoPem();

        _logger.LogDebug("Public key exported successfully (length: {Length} chars)", publicKeyPem.Length);

        return publicKeyPem;
    }

    public string ExportPublicKeyJwk(RSA rsa)
    {
        if (rsa == null)
            throw new ArgumentNullException(nameof(rsa));

        _logger.LogDebug("Exporting public key as JWK");

        var parameters = rsa.ExportParameters(false); // Public key only

        // Convert RSA parameters to JWK format
        var jwk = new
        {
            kty = "RSA",
            use = "enc", // Encryption
            kid = Guid.NewGuid().ToString(), // Key ID
            n = Base64UrlEncode(parameters.Modulus!),
            e = Base64UrlEncode(parameters.Exponent!)
        };

        var jwkJson = JsonSerializer.Serialize(jwk, new JsonSerializerOptions
        {
            WriteIndented = true
        });

        _logger.LogDebug("Public key exported as JWK successfully (KeyId: {KeyId})", jwk.kid);

        return jwkJson;
    }

    public bool ValidateKeyPair(string privateKeyPem, string publicKeyPem)
    {
        if (string.IsNullOrEmpty(privateKeyPem))
            throw new ArgumentNullException(nameof(privateKeyPem));
        if (string.IsNullOrEmpty(publicKeyPem))
            throw new ArgumentNullException(nameof(publicKeyPem));

        try
        {
            _logger.LogDebug("Validating RSA key pair");

            using var rsaPrivate = RSA.Create();
            rsaPrivate.ImportFromPem(privateKeyPem);

            using var rsaPublic = ImportPublicKeyFromPem(publicKeyPem);

            // Test data to encrypt/decrypt
            var testData = Encoding.UTF8.GetBytes("JIT Authentication Test Payload");

            // Encrypt with public key
            var encrypted = rsaPublic.Encrypt(testData, RSAEncryptionPadding.OaepSHA256);

            // Decrypt with private key
            var decrypted = rsaPrivate.Decrypt(encrypted, RSAEncryptionPadding.OaepSHA256);

            // Verify data matches
            var isValid = testData.SequenceEqual(decrypted);

            _logger.LogInformation("Key pair validation: {Result}", isValid ? "SUCCESS" : "FAILED");

            return isValid;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Key pair validation failed with exception");
            return false;
        }
    }

    public RSA ImportPublicKeyFromPem(string publicKeyPem)
    {
        if (string.IsNullOrEmpty(publicKeyPem))
            throw new ArgumentNullException(nameof(publicKeyPem));

        _logger.LogDebug("Importing public key from PEM");

        var rsa = RSA.Create();
        rsa.ImportFromPem(publicKeyPem);

        _logger.LogDebug("Public key imported successfully");

        return rsa;
    }

    /// <summary>
    /// Base64URL encodes a byte array (used for JWK format).
    /// </summary>
    private static string Base64UrlEncode(byte[] input)
    {
        var base64 = Convert.ToBase64String(input);

        // Convert to Base64URL by replacing characters and removing padding
        return base64
            .Replace('+', '-')
            .Replace('/', '_')
            .TrimEnd('=');
    }
}
