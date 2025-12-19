// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
using System.ComponentModel.DataAnnotations;

namespace B2CMigrationKit.Core.Configuration;

/// <summary>
/// Configuration options for Azure Storage.
/// </summary>
public class StorageOptions
{
    /// <summary>
    /// Gets or sets the storage account connection string or service URI.
    /// Use Managed Identity by providing only the URI (e.g., https://account.blob.core.windows.net).
    /// </summary>
    [Required]
    public string ConnectionStringOrUri { get; set; } = string.Empty;

    /// <summary>
    /// Gets or sets the container name for exported user data.
    /// </summary>
    [Required]
    public string ExportContainerName { get; set; } = "user-exports";

    /// <summary>
    /// Gets or sets the container name for import errors and logs.
    /// </summary>
    public string ErrorContainerName { get; set; } = "migration-errors";

    /// <summary>
    /// Gets or sets the container name for import audit logs.
    /// </summary>
    public string ImportAuditContainerName { get; set; } = "import-audit";

    /// <summary>
    /// Gets or sets the queue name for profile sync messages.
    /// </summary>
    public string ProfileSyncQueueName { get; set; } = "profile-updates";

    /// <summary>
    /// Gets or sets the blob name prefix for export files.
    /// </summary>
    public string ExportBlobPrefix { get; set; } = "users_";

    /// <summary>
    /// Gets or sets whether to use Managed Identity for authentication (default: true).
    /// </summary>
    public bool UseManagedIdentity { get; set; } = true;
}
