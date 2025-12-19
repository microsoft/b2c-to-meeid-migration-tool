// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
using System.ComponentModel.DataAnnotations;

namespace B2CMigrationKit.Core.Configuration;

/// <summary>
/// Configuration options for retry policies and throttling handling.
/// </summary>
public class RetryOptions
{
    /// <summary>
    /// Gets or sets the maximum number of retry attempts (default: 5).
    /// </summary>
    [Range(0, 20)]
    public int MaxRetries { get; set; } = 5;

    /// <summary>
    /// Gets or sets the initial retry delay in milliseconds (default: 1000).
    /// </summary>
    [Range(100, 60000)]
    public int InitialDelayMs { get; set; } = 1000;

    /// <summary>
    /// Gets or sets the maximum retry delay in milliseconds (default: 30000).
    /// </summary>
    [Range(1000, 300000)]
    public int MaxDelayMs { get; set; } = 30000;

    /// <summary>
    /// Gets or sets the exponential backoff multiplier (default: 2.0).
    /// </summary>
    [Range(1.0, 10.0)]
    public double BackoffMultiplier { get; set; } = 2.0;

    /// <summary>
    /// Gets or sets whether to respect Retry-After headers from API responses (default: true).
    /// </summary>
    public bool UseRetryAfterHeader { get; set; } = true;

    /// <summary>
    /// Gets or sets the timeout for individual operations in seconds (default: 120).
    /// </summary>
    [Range(10, 600)]
    public int OperationTimeoutSeconds { get; set; } = 120;

    /// <summary>
    /// Gets or sets HTTP status codes that should trigger a retry.
    /// </summary>
    public int[] RetryableStatusCodes { get; set; } = new[] { 429, 500, 502, 503, 504 };
}
