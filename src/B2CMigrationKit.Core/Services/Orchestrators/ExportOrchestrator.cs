// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
using B2CMigrationKit.Core.Abstractions;
using B2CMigrationKit.Core.Configuration;
using B2CMigrationKit.Core.Models;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using System.Text.Json;

namespace B2CMigrationKit.Core.Services.Orchestrators;

/// <summary>
/// Orchestrates the bulk export of users from Azure AD B2C to Blob Storage.
/// </summary>
public class ExportOrchestrator : IOrchestrator<ExecutionResult>
{
    private readonly IGraphClient _b2cGraphClient;
    private readonly IBlobStorageClient _blobClient;
    private readonly ITelemetryService _telemetry;
    private readonly ILogger<ExportOrchestrator> _logger;
    private readonly MigrationOptions _options;

    public ExportOrchestrator(
        IGraphClient b2cGraphClient,
        IBlobStorageClient blobClient,
        ITelemetryService telemetry,
        IOptions<MigrationOptions> options,
        ILogger<ExportOrchestrator> logger)
    {
        _b2cGraphClient = b2cGraphClient ?? throw new ArgumentNullException(nameof(b2cGraphClient));
        _blobClient = blobClient ?? throw new ArgumentNullException(nameof(blobClient));
        _telemetry = telemetry ?? throw new ArgumentNullException(nameof(telemetry));
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
        _options = options?.Value ?? throw new ArgumentNullException(nameof(options));
    }

    public async Task<ExecutionResult> ExecuteAsync(CancellationToken cancellationToken = default)
    {
        var summary = new RunSummary
        {
            OperationName = "B2C User Export",
            StartTime = DateTimeOffset.UtcNow
        };

        try
        {
            _logger.LogInformation("Starting B2C user export");
            _telemetry.TrackEvent("Export.Started");

            // Ensure export container exists
            await _blobClient.EnsureContainerExistsAsync(
                _options.Storage.ExportContainerName,
                cancellationToken);

            var select = _options.Export.SelectFields;
            _logger.LogInformation("Export fields: {SelectFields}", select);

            // Check if filter pattern is specified
            var hasFilter = !string.IsNullOrWhiteSpace(_options.Export.FilterPattern);
            var filterPattern = hasFilter ? _options.Export.FilterPattern!.Trim().ToLower() : null;
            var exportedUserIds = new HashSet<string>(); // Track exported users to avoid duplicates with client-side filtering
            
            if (hasFilter)
            {
                _logger.LogInformation("Export filter pattern: {Pattern} (will filter displayName and userPrincipalName client-side)", filterPattern);
            }

            var pageNumber = 0;
            string? skipToken = null;
            var overallStartTime = DateTimeOffset.UtcNow;
            var lastBlobSizeBytes = 0;

            do
            {
                var batchStartTime = DateTimeOffset.UtcNow;
                
                var page = await _b2cGraphClient.GetUsersAsync(
                    pageSize: _options.PageSize,
                    select: select,
                    skipToken: skipToken,
                    cancellationToken: cancellationToken);

                var fetchDuration = (DateTimeOffset.UtcNow - batchStartTime).TotalMilliseconds;

                // Apply client-side filtering if pattern is specified
                var filteredItems = page.Items;
                if (hasFilter && filterPattern != null)
                {
                    var beforeFilterCount = page.Items.Count;
                    
                    filteredItems = page.Items.Where(u =>
                        !string.IsNullOrEmpty(u.Id) &&
                        !exportedUserIds.Contains(u.Id) && // Skip already exported users
                        ((u.DisplayName?.ToLower().Contains(filterPattern) ?? false) ||
                         (u.UserPrincipalName?.ToLower().Contains(filterPattern) ?? false))
                    ).ToList();

                    // Mark these users as exported
                    foreach (var user in filteredItems)
                    {
                        if (!string.IsNullOrEmpty(user.Id))
                        {
                            exportedUserIds.Add(user.Id);
                        }
                    }

                    var duplicatesSkipped = beforeFilterCount - filteredItems.Count;
                    if (duplicatesSkipped > 0)
                    {
                        _logger.LogDebug(
                            "Filtered batch: {Original} users fetched, {Filtered} matched filter pattern (including {New} new users, {Duplicates} duplicates skipped)",
                            beforeFilterCount, filteredItems.Count, filteredItems.Count, duplicatesSkipped - filteredItems.Count);
                    }
                }

                if (filteredItems.Any())
                {
                    var serializeStartTime = DateTimeOffset.UtcNow;
                    
                    // Write page to blob
                    var blobName = $"{_options.Storage.ExportBlobPrefix}{pageNumber:D6}.json";
                    var json = JsonSerializer.Serialize(filteredItems, new JsonSerializerOptions
                    {
                        WriteIndented = true
                    });

                    lastBlobSizeBytes = System.Text.Encoding.UTF8.GetByteCount(json);

                    var serializeDuration = (DateTimeOffset.UtcNow - serializeStartTime).TotalMilliseconds;
                    var uploadStartTime = DateTimeOffset.UtcNow;

                    await _blobClient.WriteBlobAsync(
                        _options.Storage.ExportContainerName,
                        blobName,
                        json,
                        cancellationToken);

                    var uploadDuration = (DateTimeOffset.UtcNow - uploadStartTime).TotalMilliseconds;
                    var totalBatchDuration = (DateTimeOffset.UtcNow - batchStartTime).TotalMilliseconds;

                    summary.TotalItems += filteredItems.Count;
                    summary.SuccessCount += filteredItems.Count;

                    var elapsedTotal = (DateTimeOffset.UtcNow - overallStartTime).TotalSeconds;
                    var currentThroughput = summary.TotalItems / elapsedTotal;

                    _logger.LogInformation(
                        "Batch {Page}: {Count} users | Fetch: {FetchMs:F0}ms | Serialize: {SerializeMs:F0}ms | Upload: {UploadMs:F0}ms | Total: {TotalMs:F0}ms | Throughput: {TotalUsers} users in {Elapsed:F1}s ({Rate:F1} users/s)",
                        pageNumber, filteredItems.Count, fetchDuration, serializeDuration, uploadDuration, totalBatchDuration,
                        summary.TotalItems, elapsedTotal, currentThroughput);

                    _telemetry.IncrementCounter("Export.UsersExported", filteredItems.Count);
                    _telemetry.TrackMetric("Export.BatchDurationMs", totalBatchDuration);
                    _telemetry.TrackMetric("Export.FetchDurationMs", fetchDuration);
                    _telemetry.TrackMetric("Export.UploadDurationMs", uploadDuration);
                }

                skipToken = page.NextPageToken;
                pageNumber++;

                // Check if we've reached the max user limit
                if (_options.Export.MaxUsers.HasValue && _options.Export.MaxUsers.Value > 0 && 
                    summary.TotalItems >= _options.Export.MaxUsers.Value)
                {
                    _logger.LogInformation("Reached max user limit of {MaxUsers}. Stopping export.", _options.Export.MaxUsers.Value);
                    break;
                }

                // Add delay between batches if configured
                if (_options.BatchDelayMs > 0 && page.HasMorePages)
                {
                    await Task.Delay(_options.BatchDelayMs, cancellationToken);
                }

            } while (!string.IsNullOrEmpty(skipToken) && !cancellationToken.IsCancellationRequested);

            summary.EndTime = DateTimeOffset.UtcNow;

            // Calculate projections for large-scale migrations
            var totalDurationSeconds = summary.Duration.TotalSeconds;
            var finalThroughput = summary.TotalItems / totalDurationSeconds;
            var projection1M = TimeSpan.FromSeconds(1_000_000 / finalThroughput);
            var avgBatchSize = pageNumber > 0 ? summary.TotalItems / (double)pageNumber : 0;
            var estimatedStorageFor1M = lastBlobSizeBytes > 0 && avgBatchSize > 0 
                ? (long)((lastBlobSizeBytes / avgBatchSize) * 1_000_000)
                : 0;

            _logger.LogInformation(
                "=== EXPORT SUMMARY ===\n" +
                "Users Exported: {TotalUsers:N0}\n" +
                "Batches: {Batches}\n" +
                "Duration: {Duration}\n" +
                "Throughput: {Throughput:F2} users/second\n" +
                "Avg Batch Size: {AvgBatch:F0} users\n" +
                "--- PROJECTIONS FOR 1 MILLION USERS ---\n" +
                "Estimated Time (single instance): {Projection1M}\n" +
                "Estimated Storage: {EstimatedStorage:N0} bytes (~{EstimatedStorageMB:F2} MB)\n" +
                "With 3 instances (different IPs): ~{Projection1M_3x}\n" +
                "With 5 instances (different IPs): ~{Projection1M_5x}",
                summary.TotalItems,
                pageNumber,
                summary.Duration,
                finalThroughput,
                avgBatchSize,
                projection1M,
                estimatedStorageFor1M,
                estimatedStorageFor1M / (1024.0 * 1024.0),
                TimeSpan.FromSeconds(projection1M.TotalSeconds / 3),
                TimeSpan.FromSeconds(projection1M.TotalSeconds / 5));

            _logger.LogInformation(summary.ToString());
            
            // Track aggregated metrics for cost estimation
            _telemetry.TrackMetric("export.storage.total.bytes", estimatedStorageFor1M);
            _telemetry.TrackMetric("export.storage.avg.bytes.per.user", 
                summary.TotalItems > 0 ? estimatedStorageFor1M / 1_000_000.0 : 0);
            _telemetry.TrackMetric("export.duration.total.seconds", totalDurationSeconds);
            _telemetry.TrackMetric("export.throughput.users.per.second", finalThroughput);
            
            _telemetry.TrackEvent("Export.Completed", new Dictionary<string, string>
            {
                { "TotalUsers", summary.TotalItems.ToString() },
                { "Duration", summary.Duration.ToString() },
                { "Throughput", finalThroughput.ToString("F2") },
                { "Projection1M", projection1M.ToString() },
                { "EstimatedStorageBytes", estimatedStorageFor1M.ToString() }
            });

            await _telemetry.FlushAsync();

            return new ExecutionResult
            {
                Success = true,
                StartTime = summary.StartTime,
                EndTime = summary.EndTime,
                Summary = summary
            };
        }
        catch (Exception ex)
        {
            summary.EndTime = DateTimeOffset.UtcNow;
            _logger.LogError(ex, "Export failed");
            _telemetry.TrackException(ex);

            return new ExecutionResult
            {
                Success = false,
                ErrorMessage = ex.Message,
                Exception = ex,
                StartTime = summary.StartTime,
                EndTime = summary.EndTime,
                Summary = summary
            };
        }
    }
}
