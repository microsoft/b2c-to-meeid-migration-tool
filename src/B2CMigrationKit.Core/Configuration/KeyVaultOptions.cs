// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
using System.ComponentModel.DataAnnotations;

namespace B2CMigrationKit.Core.Configuration;

/// <summary>
/// Configuration options for Azure Key Vault.
/// </summary>
public class KeyVaultOptions
{
    /// <summary>
    /// Gets or sets whether Key Vault integration is enabled (default: false).
    /// When false, Key Vault services are not registered and inline secrets are used.
    /// </summary>
    public bool Enabled { get; set; } = false;

    /// <summary>
    /// Gets or sets the Key Vault URI (e.g., https://myvault.vault.azure.net/).
    /// Required when Enabled = true.
    /// </summary>
    [Url]
    public string? VaultUri { get; set; }

    /// <summary>
    /// Gets or sets whether to use Managed Identity for authentication (default: true).
    /// When true, uses Azure Managed Identity (recommended for production).
    /// When false, falls back to DefaultAzureCredential (Visual Studio, Azure CLI, etc.).
    /// </summary>
    public bool UseManagedIdentity { get; set; } = true;

    /// <summary>
    /// Gets or sets the cache duration for secrets in minutes (default: 60).
    /// </summary>
    [Range(1, 1440)]
    public int SecretCacheDurationMinutes { get; set; } = 60;
}
