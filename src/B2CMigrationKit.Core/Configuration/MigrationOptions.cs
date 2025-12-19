// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
using System.ComponentModel.DataAnnotations;

namespace B2CMigrationKit.Core.Configuration;

/// <summary>
/// Main configuration options for the B2C migration toolkit.
/// </summary>
public class MigrationOptions
{
    /// <summary>
    /// Configuration section name.
    /// </summary>
    public const string SectionName = "Migration";

    /// <summary>
    /// Gets or sets the Azure AD B2C configuration.
    /// </summary>
    [Required]
    public B2COptions B2C { get; set; } = new();

    /// <summary>
    /// Gets or sets the Entra External ID configuration.
    /// </summary>
    [Required]
    public ExternalIdOptions ExternalId { get; set; } = new();

    /// <summary>
    /// Gets or sets the Azure Storage configuration.
    /// </summary>
    [Required]
    public StorageOptions Storage { get; set; } = new();

    /// <summary>
    /// Gets or sets the Azure Key Vault configuration.
    /// </summary>
    public KeyVaultOptions? KeyVault { get; set; }

    /// <summary>
    /// Gets or sets the telemetry configuration.
    /// </summary>
    public TelemetryOptions Telemetry { get; set; } = new();

    /// <summary>
    /// Gets or sets the retry policy configuration.
    /// </summary>
    public RetryOptions Retry { get; set; } = new();

    /// <summary>
    /// Gets or sets the export configuration.
    /// </summary>
    public ExportOptions Export { get; set; } = new();

    /// <summary>
    /// Gets or sets the import configuration.
    /// </summary>
    public ImportOptions Import { get; set; } = new();

    /// <summary>
    /// Gets or sets the JIT authentication configuration.
    /// </summary>
    public JitAuthenticationOptions JitAuthentication { get; set; } = new();

    /// <summary>
    /// Gets or sets the batch size for operations (default: 100).
    /// </summary>
    [Range(1, 1000)]
    public int BatchSize { get; set; } = 100;

    /// <summary>
    /// Gets or sets the page size for Graph API queries (default: 100).
    /// </summary>
    [Range(1, 999)]
    public int PageSize { get; set; } = 100;

    /// <summary>
    /// Gets or sets whether to enable verbose logging (default: false).
    /// </summary>
    public bool VerboseLogging { get; set; } = false;

    /// <summary>
    /// Gets or sets the delay between batches in milliseconds (default: 0).
    /// </summary>
    [Range(0, 10000)]
    public int BatchDelayMs { get; set; } = 0;
}
