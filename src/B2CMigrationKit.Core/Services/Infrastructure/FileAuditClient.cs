// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
using B2CMigrationKit.Core.Abstractions;
using B2CMigrationKit.Core.Configuration;
using B2CMigrationKit.Core.Models;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using System.Text.Json;

namespace B2CMigrationKit.Core.Services.Infrastructure;

/// <summary>
/// Audit client that writes migration records to a local JSONL file instead of Azure Table Storage.
/// Useful for local development and testing where Azurite is not available or causes contention.
/// Records are appended one JSON object per line; multiple runs accumulate in the same file.
/// Thread-safe: a semaphore serialises concurrent writes from async code.
/// </summary>
public class FileAuditClient : ITableStorageClient
{
    private readonly string _filePath;
    private readonly ILogger<FileAuditClient> _logger;
    private readonly SemaphoreSlim _writeLock = new(1, 1);

    private static readonly JsonSerializerOptions _jsonOptions = new()
    {
        WriteIndented = false
    };

    public FileAuditClient(IOptions<MigrationOptions> options, ILogger<FileAuditClient> logger)
    {
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
        _filePath = options?.Value?.Storage?.AuditFilePath
            ?? throw new ArgumentNullException(nameof(options));

        var dir = Path.GetDirectoryName(Path.GetFullPath(_filePath));
        if (!string.IsNullOrEmpty(dir))
            Directory.CreateDirectory(dir);

        _logger.LogInformation("[Audit] File audit enabled — writing to: {Path}", Path.GetFullPath(_filePath));
    }

    /// <summary>No-op: file does not need pre-creation.</summary>
    public Task EnsureTableExistsAsync(string tableName, CancellationToken cancellationToken = default)
        => Task.CompletedTask;

    public async Task UpsertAuditRecordAsync(
        MigrationAuditRecord record,
        string tableName,
        CancellationToken cancellationToken = default)
    {
        // Project to a plain anonymous object to avoid serialising Azure SDK types (ETag, etc.)
        bool? mfaMigrated = record.Stage == "phone"
            ? record.Status == "PhoneRegistered" ? (bool?)true
              : record.Status == "PhoneSkipped"  ? (bool?)false
              : (bool?)null
            : (bool?)null;

        var entry = new
        {
            record.PartitionKey,
            record.RowKey,
            record.B2CObjectId,
            record.ExternalIdObjectId,
            record.EEIDUpn,
            record.Stage,
            record.Status,
            MfaMigrated = mfaMigrated,
            record.ErrorCode,
            record.ErrorMessage,
            record.DurationMs,
            record.TimestampUtc
        };

        var line = JsonSerializer.Serialize(entry, _jsonOptions) + Environment.NewLine;

        await _writeLock.WaitAsync(cancellationToken);
        try
        {
            await File.AppendAllTextAsync(_filePath, line, cancellationToken);
        }
        catch (Exception ex)
        {
            // Audit failures must not block the migration pipeline — log and continue.
            _logger.LogWarning(ex,
                "[Audit] Failed to write audit record to file '{Path}'", _filePath);
        }
        finally
        {
            _writeLock.Release();
        }
    }
}
