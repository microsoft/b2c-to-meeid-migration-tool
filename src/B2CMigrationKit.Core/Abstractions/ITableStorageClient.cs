// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
using B2CMigrationKit.Core.Models;

namespace B2CMigrationKit.Core.Abstractions;

/// <summary>
/// Provides access to Azure Table Storage for writing migration audit records.
/// </summary>
public interface ITableStorageClient
{
    /// <summary>
    /// Creates the table if it does not already exist.
    /// </summary>
    Task EnsureTableExistsAsync(string tableName, CancellationToken cancellationToken = default);

    /// <summary>
    /// Inserts or replaces an audit record in the specified table.
    /// </summary>
    Task UpsertAuditRecordAsync(
        MigrationAuditRecord record,
        string tableName,
        CancellationToken cancellationToken = default);
}
