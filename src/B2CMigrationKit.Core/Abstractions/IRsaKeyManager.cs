// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
namespace B2CMigrationKit.Core.Abstractions;

/// <summary>
/// Provides RSA public key export and validation utilities for JIT authentication.
/// RSA key pairs are generated and stored in Azure Key Vault - private keys never leave Key Vault.
/// This interface helps export public keys for External ID configuration.
/// </summary>
public interface IRsaKeyManager
{
    /// <summary>
    /// Exports a public key in PEM format from an RSA instance.
    /// Used to display the public key for manual configuration in External ID.
    /// </summary>
    /// <param name="rsa">RSA instance containing the public key</param>
    /// <returns>Public key as PEM-encoded string</returns>
    string ExportPublicKeyPem(System.Security.Cryptography.RSA rsa);

    /// <summary>
    /// Exports a public key in JWK (JSON Web Key) format for External ID configuration.
    /// The JWK format is required by External ID Custom Authentication Extension for payload encryption.
    /// </summary>
    /// <param name="rsa">RSA instance containing the public key</param>
    /// <returns>Public key as JWK JSON string</returns>
    string ExportPublicKeyJwk(System.Security.Cryptography.RSA rsa);

    /// <summary>
    /// Validates that a public/private key pair match by performing encryption/decryption test.
    /// </summary>
    /// <param name="privateKeyPem">Private key in PEM format</param>
    /// <param name="publicKeyPem">Public key in PEM format</param>
    /// <returns>True if keys are a valid pair, false otherwise</returns>
    bool ValidateKeyPair(string privateKeyPem, string publicKeyPem);

    /// <summary>
    /// Imports an RSA public key from PEM format.
    /// Used to load public keys exported from Key Vault for validation.
    /// </summary>
    /// <param name="publicKeyPem">Public key in PEM format</param>
    /// <returns>RSA instance with the imported public key</returns>
    System.Security.Cryptography.RSA ImportPublicKeyFromPem(string publicKeyPem);

    /// <summary>
    /// Generates a local RSA key pair for development/testing purposes only.
    /// PRODUCTION: Use Azure Key Vault to generate keys (New-AzKeyVaultKey).
    /// </summary>
    /// <param name="keySizeInBits">Key size in bits (2048 or 4096 recommended)</param>
    /// <returns>RSA instance containing the key pair</returns>
    System.Security.Cryptography.RSA GenerateKeyPairForTesting(int keySizeInBits = 2048);
}
