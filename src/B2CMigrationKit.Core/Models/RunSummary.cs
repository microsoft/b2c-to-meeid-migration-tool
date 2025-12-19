// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
namespace B2CMigrationKit.Core.Models;

/// <summary>
/// Represents a summary of an execution run with metrics and counts.
/// </summary>
public class RunSummary
{
    /// <summary>
    /// Gets or sets the name of the operation.
    /// </summary>
    public string? OperationName { get; set; }

    /// <summary>
    /// Gets or sets the start time of the run.
    /// </summary>
    public DateTimeOffset StartTime { get; set; }

    /// <summary>
    /// Gets or sets the end time of the run.
    /// </summary>
    public DateTimeOffset EndTime { get; set; }

    /// <summary>
    /// Gets the duration of the run.
    /// </summary>
    public TimeSpan Duration => EndTime - StartTime;

    /// <summary>
    /// Gets or sets the total number of items processed.
    /// </summary>
    public int TotalItems { get; set; }

    /// <summary>
    /// Gets or sets the number of successful items.
    /// </summary>
    public int SuccessCount { get; set; }

    /// <summary>
    /// Gets or sets the number of failed items.
    /// </summary>
    public int FailureCount { get; set; }

    /// <summary>
    /// Gets or sets the number of skipped items.
    /// </summary>
    public int SkippedCount { get; set; }

    /// <summary>
    /// Gets or sets the number of times throttling was encountered.
    /// </summary>
    public int ThrottleCount { get; set; }

    /// <summary>
    /// Gets or sets the total number of retries performed.
    /// </summary>
    public int RetryCount { get; set; }

    /// <summary>
    /// Gets or sets the throughput in items per second.
    /// </summary>
    public double ItemsPerSecond
    {
        get
        {
            var seconds = Duration.TotalSeconds;
            return seconds > 0 ? TotalItems / seconds : 0;
        }
    }

    /// <summary>
    /// Gets or sets custom metrics for the run.
    /// </summary>
    public Dictionary<string, double> Metrics { get; set; } = new();

    /// <summary>
    /// Gets or sets additional context and metadata.
    /// </summary>
    public Dictionary<string, string> Context { get; set; } = new();

    /// <summary>
    /// Returns a formatted summary string for logging.
    /// </summary>
    public override string ToString()
    {
        return $"RUN SUMMARY: {OperationName} | Duration: {Duration:hh\\:mm\\:ss} | " +
               $"Total: {TotalItems} | Success: {SuccessCount} | Failed: {FailureCount} | " +
               $"Skipped: {SkippedCount} | Throttles: {ThrottleCount} | " +
               $"Throughput: {ItemsPerSecond:F2} items/sec";
    }
}
