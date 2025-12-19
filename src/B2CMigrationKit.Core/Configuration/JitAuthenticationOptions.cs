// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
namespace B2CMigrationKit.Core.Configuration;

/// <summary>
/// Configuration options for JIT (Just-In-Time) authentication during migration.
/// </summary>
public class JitAuthenticationOptions
{
    /// <summary>
    /// Gets or sets the name of the RSA private key in Azure Key Vault.
    /// This key is used to decrypt the password context sent by External ID.
    /// Default: "JIT-RSA-PrivateKey"
    /// </summary>
    public string RsaKeyName { get; set; } = "JIT-RSA-PrivateKey";

    /// <summary>
    /// Gets or sets whether to use Azure Key Vault for RSA private key storage.
    /// When true, the key is retrieved from Key Vault using Managed Identity.
    /// When false, falls back to inline key in configuration (local development only).
    /// Default: true (production should always use Key Vault)
    /// </summary>
    public bool UseKeyVault { get; set; } = true;

    /// <summary>
    /// Gets or sets the inline RSA private key in PEM format for local development.
    /// WARNING: Only use this for local development. Never commit actual keys to source control.
    /// Production deployments must use Azure Key Vault (UseKeyVault = true).
    /// </summary>
    public string? InlineRsaPrivateKey { get; set; }

    /// <summary>
    /// Gets or sets the timeout in seconds for JIT authentication operations.
    /// External ID has a 2-second timeout, so this should be less than that.
    /// Default: 1.5 seconds
    /// </summary>
    public double TimeoutSeconds { get; set; } = 1.5;

    /// <summary>
    /// Gets or sets whether to cache the RSA private key in memory after first retrieval.
    /// Reduces Key Vault calls but keeps key in memory.
    /// Default: true
    /// </summary>
    public bool CachePrivateKey { get; set; } = true;

    /// <summary>
    /// Gets or sets whether to enable Test Mode for JIT migration.
    /// When true, skips B2C ROPC validation and password complexity checks.
    /// WARNING: Only use for local development and testing. Must be false in production.
    /// Default: false (production mode)
    /// </summary>
    public bool TestMode { get; set; } = false;

    /// <summary>
    /// Gets or sets the name of the custom attribute used to trigger JIT migration.
    /// This attribute must be configured in External ID Custom Authentication Extension.
    /// When this attribute is true AND password doesn't match, JIT is triggered.
    /// Default: "RequiresMigration"
    /// </summary>
    public string MigrationAttributeName { get; set; } = "RequiresMigration";
}
