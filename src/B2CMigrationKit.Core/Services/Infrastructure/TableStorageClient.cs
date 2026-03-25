// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
using Azure.Data.Tables;
using B2CMigrationKit.Core.Abstractions;
using B2CMigrationKit.Core.Configuration;
using B2CMigrationKit.Core.Models;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace B2CMigrationKit.Core.Services.Infrastructure;

/// <summary>
/// Azure Table Storage client for writing migration audit records.
/// Uses the same connection string as Blob Storage and Queue Storage.
/// </summary>
public class TableStorageClient : ITableStorageClient
{
    private readonly TableServiceClient _serviceClient;
    private readonly ILogger<TableStorageClient> _logger;

    public TableStorageClient(IOptions<MigrationOptions> options, ILogger<TableStorageClient> logger)
    {
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
        var connectionString = options?.Value?.Storage?.ConnectionStringOrUri
            ?? throw new ArgumentNullException(nameof(options));

        _serviceClient = new TableServiceClient(connectionString);
    }

    public async Task EnsureTableExistsAsync(string tableName, CancellationToken cancellationToken = default)
    {
        try
        {
            await _serviceClient.CreateTableIfNotExistsAsync(tableName, cancellationToken);
            _logger.LogDebug("Table '{Table}' ready.", tableName);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to create table '{Table}'", tableName);
            throw;
        }
    }

    public async Task UpsertAuditRecordAsync(
        MigrationAuditRecord record,
        string tableName,
        CancellationToken cancellationToken = default)
    {
        try
        {
            var tableClient = _serviceClient.GetTableClient(tableName);
            await tableClient.UpsertEntityAsync(record, TableUpdateMode.Replace, cancellationToken);
        }
        catch (Exception ex)
        {
            // Audit failures must not block the migration pipeline — log and continue.
            _logger.LogWarning(ex,
                "Failed to write audit record PartitionKey={PK} RowKey={RK} to table '{Table}'",
                record.PartitionKey, record.RowKey, tableName);
        }
    }
}
