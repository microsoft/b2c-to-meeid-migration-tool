// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
namespace B2CMigrationKit.Core.Models;

/// <summary>
/// Represents the result of an orchestration execution.
/// </summary>
public class ExecutionResult
{
    /// <summary>
    /// Gets or sets whether the execution was successful.
    /// </summary>
    public bool Success { get; set; }

    /// <summary>
    /// Gets or sets the error message if the execution failed.
    /// </summary>
    public string? ErrorMessage { get; set; }

    /// <summary>
    /// Gets or sets the exception if one occurred.
    /// </summary>
    public Exception? Exception { get; set; }

    /// <summary>
    /// Gets or sets the start time of the execution.
    /// </summary>
    public DateTimeOffset StartTime { get; set; }

    /// <summary>
    /// Gets or sets the end time of the execution.
    /// </summary>
    public DateTimeOffset EndTime { get; set; }

    /// <summary>
    /// Gets the duration of the execution.
    /// </summary>
    public TimeSpan Duration => EndTime - StartTime;

    /// <summary>
    /// Gets or sets the run summary with metrics and counts.
    /// </summary>
    public RunSummary? Summary { get; set; }

    /// <summary>
    /// Gets or sets additional metadata about the execution.
    /// </summary>
    public Dictionary<string, object> Metadata { get; set; } = new();

    /// <summary>
    /// Creates a successful execution result.
    /// </summary>
    public static ExecutionResult CreateSuccess(RunSummary? summary = null)
    {
        return new ExecutionResult
        {
            Success = true,
            Summary = summary,
            EndTime = DateTimeOffset.UtcNow
        };
    }

    /// <summary>
    /// Creates a failed execution result.
    /// </summary>
    public static ExecutionResult CreateFailure(string errorMessage, Exception? exception = null)
    {
        return new ExecutionResult
        {
            Success = false,
            ErrorMessage = errorMessage,
            Exception = exception,
            EndTime = DateTimeOffset.UtcNow
        };
    }
}
