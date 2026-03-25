// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
using B2CMigrationKit.Core.Abstractions;
using B2CMigrationKit.Core.Configuration;
using B2CMigrationKit.Core.Models;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace B2CMigrationKit.Core.Services.Orchestrators;

/// <summary>
/// Validates connectivity to all external dependencies:
/// Azure AD B2C Graph API, Entra External ID Graph API, and Azure Storage (queues/blobs).
/// Designed to run on worker VMs before starting migration operations.
/// </summary>
public class ValidateOrchestrator : IOrchestrator<ExecutionResult>
{
    private readonly IGraphClient _b2cGraphClient;
    private readonly IGraphClient? _eeidGraphClient;
    private readonly IQueueClient _queueClient;
    private readonly IBlobStorageClient _blobClient;
    private readonly ILogger<ValidateOrchestrator> _logger;
    private readonly MigrationOptions _options;

    public ValidateOrchestrator(
        IGraphClient b2cGraphClient,
        IGraphClient? eeidGraphClient,
        IQueueClient queueClient,
        IBlobStorageClient blobClient,
        IOptions<MigrationOptions> options,
        ILogger<ValidateOrchestrator> logger)
    {
        _b2cGraphClient = b2cGraphClient ?? throw new ArgumentNullException(nameof(b2cGraphClient));
        _eeidGraphClient = eeidGraphClient;
        _queueClient = queueClient ?? throw new ArgumentNullException(nameof(queueClient));
        _blobClient = blobClient ?? throw new ArgumentNullException(nameof(blobClient));
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
        _options = options?.Value ?? throw new ArgumentNullException(nameof(options));
    }

    public async Task<ExecutionResult> ExecuteAsync(CancellationToken cancellationToken = default)
    {
        var startTime = DateTimeOffset.UtcNow;
        var checks = new List<(string Name, bool Passed, string Detail)>();

        // 1. B2C Graph API
        checks.Add(await CheckB2CGraphAsync(cancellationToken));

        // 2. Entra External ID Graph API (skip if disabled — master/harvest role)
        if (_eeidGraphClient != null)
        {
            checks.Add(await CheckEeidGraphAsync(cancellationToken));
        }
        else
        {
            checks.Add(("Entra External ID Graph API", true, "SKIPPED — disabled for this role"));
        }

        // 3. Azure Queue Storage
        checks.Add(await CheckQueueStorageAsync(cancellationToken));

        // 4. Azure Blob Storage
        checks.Add(await CheckBlobStorageAsync(cancellationToken));

        // Print results
        System.Console.WriteLine();
        System.Console.WriteLine("Validation Results");
        System.Console.WriteLine("==================");
        foreach (var (name, passed, detail) in checks)
        {
            var symbol = passed ? "✓" : "✗";
            var color = passed ? ConsoleColor.Green : ConsoleColor.Red;
            System.Console.ForegroundColor = color;
            System.Console.Write($"  {symbol} ");
            System.Console.ResetColor();
            System.Console.WriteLine($"{name}: {detail}");
        }
        System.Console.WriteLine();

        var allPassed = checks.All(c => c.Passed);
        var passCount = checks.Count(c => c.Passed);
        var failCount = checks.Count(c => !c.Passed);

        if (allPassed)
        {
            System.Console.ForegroundColor = ConsoleColor.Green;
            System.Console.WriteLine($"All {checks.Count} checks passed. Ready to migrate.");
            System.Console.ResetColor();
        }
        else
        {
            System.Console.ForegroundColor = ConsoleColor.Red;
            System.Console.WriteLine($"{failCount} of {checks.Count} checks failed. Fix the issues above before running migration.");
            System.Console.ResetColor();
        }

        return new ExecutionResult
        {
            Success = allPassed,
            StartTime = startTime,
            EndTime = DateTimeOffset.UtcNow,
            ErrorMessage = allPassed ? null : $"{failCount} connectivity check(s) failed",
            Summary = new RunSummary
            {
                OperationName = "Validate",
                StartTime = startTime,
                TotalItems = checks.Count,
                SuccessCount = passCount,
                FailureCount = failCount
            }
        };
    }

    private async Task<(string Name, bool Passed, string Detail)> CheckB2CGraphAsync(CancellationToken ct)
    {
        const string name = "B2C Graph API";
        try
        {
            _logger.LogInformation("Checking B2C Graph API connectivity...");
            var result = await _b2cGraphClient.GetUsersAsync(pageSize: 1, select: "id", cancellationToken: ct);
            return (name, true, $"OK — tenant reachable (found users)");
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "B2C Graph API check failed");
            return (name, false, $"FAILED — {ex.Message}");
        }
    }

    private async Task<(string Name, bool Passed, string Detail)> CheckEeidGraphAsync(CancellationToken ct)
    {
        const string name = "Entra External ID Graph API";
        try
        {
            _logger.LogInformation("Checking Entra External ID Graph API connectivity...");
            var result = await _eeidGraphClient.GetUsersAsync(pageSize: 1, select: "id", cancellationToken: ct);
            return (name, true, $"OK — tenant reachable (found users)");
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Entra External ID Graph API check failed");
            return (name, false, $"FAILED — {ex.Message}");
        }
    }

    private async Task<(string Name, bool Passed, string Detail)> CheckQueueStorageAsync(CancellationToken ct)
    {
        const string name = "Azure Queue Storage";
        try
        {
            _logger.LogInformation("Checking Azure Queue Storage connectivity...");
            var queueName = _options.Harvest?.QueueName ?? "migration-batches";
            await _queueClient.CreateQueueIfNotExistsAsync(queueName, ct);
            var length = await _queueClient.GetQueueLengthAsync(queueName, ct);
            return (name, true, $"OK — queue '{queueName}' accessible ({length} messages)");
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Azure Queue Storage check failed");
            return (name, false, $"FAILED — {ex.Message}");
        }
    }

    private async Task<(string Name, bool Passed, string Detail)> CheckBlobStorageAsync(CancellationToken ct)
    {
        const string name = "Azure Blob Storage";
        try
        {
            _logger.LogInformation("Checking Azure Blob Storage connectivity...");
            var containerName = _options.Storage?.ExportContainerName ?? "user-exports";
            await _blobClient.EnsureContainerExistsAsync(containerName, ct);
            return (name, true, $"OK — container '{containerName}' accessible");
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Azure Blob Storage check failed");
            return (name, false, $"FAILED — {ex.Message}");
        }
    }
}
