// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
using B2CMigrationKit.Core.Abstractions;
using B2CMigrationKit.Core.Models;

namespace B2CMigrationKit.Core.Services.Infrastructure;

/// <summary>
/// No-op audit client used when AuditMode is "None".
/// All audit calls succeed silently without writing anywhere.
/// </summary>
public class NullAuditClient : ITableStorageClient
{
    public Task EnsureTableExistsAsync(string tableName, CancellationToken cancellationToken = default)
        => Task.CompletedTask;

    public Task UpsertAuditRecordAsync(MigrationAuditRecord record, string tableName, CancellationToken cancellationToken = default)
        => Task.CompletedTask;
}
