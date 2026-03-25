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
    /// Gets or sets the blob name prefix for export files.
    /// </summary>
    public string ExportBlobPrefix { get; set; } = "users_";

    /// <summary>
    /// Gets or sets whether to use Managed Identity for authentication (default: true).
    /// </summary>
    public bool UseManagedIdentity { get; set; } = true;

    /// <summary>
    /// Azure Table Storage table name for migration audit records.
    /// Each <c>worker-migrate</c> user-create and <c>worker-phone</c> phone-register
    /// outcome is written here as a searchable row.
    /// Default: "migrationAudit"
    /// </summary>
    public string AuditTableName { get; set; } = "migrationAudit";

    /// <summary>
    /// Audit output mode. Controls where migration audit records are written.
    /// <list type="bullet">
    ///   <item><term>Table</term><description>Azure Table Storage (default, recommended for production)</description></item>
    ///   <item><term>File</term><description>Local JSONL file — no Azure Storage required, useful for local testing</description></item>
    ///   <item><term>None</term><description>Audit disabled — no records are written</description></item>
    /// </list>
    /// Default: "Table"
    /// </summary>
    public string AuditMode { get; set; } = "File";

    /// <summary>
    /// Path to the local JSONL audit file. Only used when <see cref="AuditMode"/> is "File".
    /// Records are appended so multiple runs accumulate in the same file.
    /// Relative paths are resolved against the working directory of the process.
    /// Default: "migration-audit.jsonl"
    /// </summary>
    public string AuditFilePath { get; set; } = "migration-audit.jsonl";
}
