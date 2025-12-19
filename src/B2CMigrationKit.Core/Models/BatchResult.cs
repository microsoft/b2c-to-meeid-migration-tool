// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
namespace B2CMigrationKit.Core.Models;

/// <summary>
/// Represents the result of a batch operation on multiple users.
/// </summary>
public class BatchResult
{
    /// <summary>
    /// Gets or sets the total number of items in the batch.
    /// </summary>
    public int TotalItems { get; set; }

    /// <summary>
    /// Gets or sets the number of successful operations.
    /// </summary>
    public int SuccessCount { get; set; }

    /// <summary>
    /// Gets or sets the number of failed operations.
    /// </summary>
    public int FailureCount { get; set; }

    /// <summary>
    /// Gets or sets the number of skipped operations (e.g., duplicates).
    /// </summary>
    public int SkippedCount { get; set; }

    /// <summary>
    /// Gets or sets details about failed items.
    /// </summary>
    public List<BatchItemFailure> Failures { get; set; } = new();

    /// <summary>
    /// Gets or sets the list of skipped user identifiers (duplicates).
    /// </summary>
    public List<string> SkippedUserIds { get; set; } = new();

    /// <summary>
    /// Gets or sets the list of duplicate users for potential extension attribute updates.
    /// </summary>
    public List<UserProfile> DuplicateUsers { get; set; } = new();

    /// <summary>
    /// Gets or sets whether the batch was throttled.
    /// </summary>
    public bool WasThrottled { get; set; }

    /// <summary>
    /// Gets or sets the retry after duration if throttled.
    /// </summary>
    public TimeSpan? RetryAfter { get; set; }

    /// <summary>
    /// Gets whether the entire batch was successful.
    /// </summary>
    public bool IsFullySuccessful => FailureCount == 0;
}

/// <summary>
/// Represents a failure for a single item in a batch operation.
/// </summary>
public class BatchItemFailure
{
    /// <summary>
    /// Gets or sets the index of the item in the batch.
    /// </summary>
    public int Index { get; set; }

    /// <summary>
    /// Gets or sets the identifier of the item (e.g., user ID or UPN).
    /// </summary>
    public string? ItemId { get; set; }

    /// <summary>
    /// Gets or sets the error message.
    /// </summary>
    public string? ErrorMessage { get; set; }

    /// <summary>
    /// Gets or sets the HTTP status code if applicable.
    /// </summary>
    public int? StatusCode { get; set; }
}
