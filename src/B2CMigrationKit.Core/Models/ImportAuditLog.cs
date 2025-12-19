// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
namespace B2CMigrationKit.Core.Models;

/// <summary>
/// Audit log for an import batch operation.
/// </summary>
public class ImportAuditLog
{
    /// <summary>
    /// Gets or sets the timestamp when this batch was processed.
    /// </summary>
    public DateTimeOffset Timestamp { get; set; }

    /// <summary>
    /// Gets or sets the source blob file name that was imported.
    /// </summary>
    public string SourceBlobName { get; set; } = string.Empty;

    /// <summary>
    /// Gets or sets the batch number being processed.
    /// </summary>
    public int BatchNumber { get; set; }

    /// <summary>
    /// Gets or sets the total number of users in this batch.
    /// </summary>
    public int TotalUsers { get; set; }

    /// <summary>
    /// Gets or sets the number of successfully imported users.
    /// </summary>
    public int SuccessCount { get; set; }

    /// <summary>
    /// Gets or sets the number of failed imports.
    /// </summary>
    public int FailureCount { get; set; }

    /// <summary>
    /// Gets or sets the number of skipped users (duplicates that already exist).
    /// </summary>
    public int SkippedCount { get; set; }

    /// <summary>
    /// Gets or sets the list of successfully imported users.
    /// </summary>
    public List<ImportedUserRecord> SuccessfulUsers { get; set; } = new();

    /// <summary>
    /// Gets or sets the list of skipped users (duplicates).
    /// </summary>
    public List<SkippedUserRecord> SkippedUsers { get; set; } = new();

    /// <summary>
    /// Gets or sets the list of failed user imports with error details.
    /// </summary>
    public List<FailedUserRecord> FailedUsers { get; set; } = new();

    /// <summary>
    /// Gets or sets the duration of this batch operation in milliseconds.
    /// </summary>
    public double DurationMs { get; set; }
}

/// <summary>
/// Record of a successfully imported user.
/// </summary>
public class ImportedUserRecord
{
    /// <summary>
    /// Gets or sets the original B2C ObjectId.
    /// </summary>
    public string B2CObjectId { get; set; } = string.Empty;

    /// <summary>
    /// Gets or sets the new External ID ObjectId.
    /// </summary>
    public string ExternalIdObjectId { get; set; } = string.Empty;

    /// <summary>
    /// Gets or sets the user principal name.
    /// </summary>
    public string UserPrincipalName { get; set; } = string.Empty;

    /// <summary>
    /// Gets or sets the user's display name.
    /// </summary>
    public string DisplayName { get; set; } = string.Empty;

    /// <summary>
    /// Gets or sets the timestamp when this user was imported.
    /// </summary>
    public DateTimeOffset ImportedAt { get; set; }
}

/// <summary>
/// Record of a skipped user (duplicate).
/// </summary>
public class SkippedUserRecord
{
    /// <summary>
    /// Gets or sets the original B2C ObjectId.
    /// </summary>
    public string B2CObjectId { get; set; } = string.Empty;

    /// <summary>
    /// Gets or sets the user principal name.
    /// </summary>
    public string UserPrincipalName { get; set; } = string.Empty;

    /// <summary>
    /// Gets or sets the user's display name.
    /// </summary>
    public string DisplayName { get; set; } = string.Empty;

    /// <summary>
    /// Gets or sets the reason for skipping.
    /// </summary>
    public string Reason { get; set; } = "Duplicate - User already exists";

    /// <summary>
    /// Gets or sets the timestamp when this user was skipped.
    /// </summary>
    public DateTimeOffset SkippedAt { get; set; }
}

/// <summary>
/// Record of a failed user import.
/// </summary>
public class FailedUserRecord
{
    /// <summary>
    /// Gets or sets the original B2C ObjectId.
    /// </summary>
    public string B2CObjectId { get; set; } = string.Empty;

    /// <summary>
    /// Gets or sets the user principal name.
    /// </summary>
    public string UserPrincipalName { get; set; } = string.Empty;

    /// <summary>
    /// Gets or sets the error message.
    /// </summary>
    public string ErrorMessage { get; set; } = string.Empty;

    /// <summary>
    /// Gets or sets the error code (if available).
    /// </summary>
    public string? ErrorCode { get; set; }

    /// <summary>
    /// Gets or sets the timestamp when this failure occurred.
    /// </summary>
    public DateTimeOffset FailedAt { get; set; }
}
