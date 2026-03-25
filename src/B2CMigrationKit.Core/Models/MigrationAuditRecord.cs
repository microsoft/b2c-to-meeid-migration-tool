// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
using Azure;
using Azure.Data.Tables;

namespace B2CMigrationKit.Core.Models;

/// <summary>
/// Azure Table Storage entity that records the outcome of a single user-migration or
/// phone-registration operation.
///
/// Partition / Row key strategy
/// ----------------------------
///   PartitionKey = run date "yyyyMMdd"  → groups all records for a day together
///   RowKey       = "{stage}_{B2CObjectId}"
///     e.g. "migrate_3b65a4de-0011-4b2c-a5f1-000000000001"
///          "phone_3b65a4de-0011-4b2c-a5f1-000000000001"
///
/// Both stages for the same user share the same B2CObjectId, allowing you to easily
/// join across rows. UpsertEntity (Replace) is used so re-running a worker over the
/// same batch always reflects the latest outcome.
/// </summary>
public class MigrationAuditRecord : ITableEntity
{
    // ---- ITableEntity required properties ----

    /// <inheritdoc />
    public string PartitionKey { get; set; } = DateTimeOffset.UtcNow.ToString("yyyyMMdd");

    /// <inheritdoc />
    /// <remarks>Format: "{stage}_{B2CObjectId}"</remarks>
    public string RowKey { get; set; } = string.Empty;

    /// <inheritdoc />
    public DateTimeOffset? Timestamp { get; set; }

    /// <inheritdoc />
    public ETag ETag { get; set; } = ETag.All;

    // ---- Domain fields ----

    /// <summary>Original B2C object ID (GUID).</summary>
    public string B2CObjectId { get; set; } = string.Empty;

    /// <summary>
    /// Object ID assigned by Entra External ID after creation.
    /// Null if the user-create step failed.
    /// </summary>
    public string? ExternalIdObjectId { get; set; }

    /// <summary>Transformed UPN in Entra External ID (post-domain-swap).</summary>
    public string? EEIDUpn { get; set; }

    /// <summary>
    /// Pipeline stage: <c>"migrate"</c> (user creation) or <c>"phone"</c> (MFA phone registration).
    /// </summary>
    public string Stage { get; set; } = string.Empty;

    /// <summary>
    /// Outcome of the operation.
    /// <list type="bullet">
    ///   <item><term>Created</term><description>User successfully created in EEID.</description></item>
    ///   <item><term>Duplicate</term><description>User already existed in EEID (409).</description></item>
    ///   <item><term>Failed</term><description>Non-recoverable error during user creation.</description></item>
    ///   <item><term>PhoneRegistered</term><description>MFA phone method successfully registered.</description></item>
    ///   <item><term>PhoneSkipped</term><description>No MFA phone found in B2C for this user.</description></item>
    ///   <item><term>PhoneFailed</term><description>Error registering phone method.</description></item>
    /// </list>
    /// </summary>
    public string Status { get; set; } = string.Empty;

    /// <summary>
    /// HTTP status code or Graph error code from the failed call.
    /// E.g. "409", "ObjectConflict", "Request_ResourceNotFound".
    /// Null on success.
    /// </summary>
    public string? ErrorCode { get; set; }

    /// <summary>
    /// Full error message / exception detail for failed rows.
    /// Truncated to 4 KB to stay within Table Storage cell limits.
    /// </summary>
    public string? ErrorMessage { get; set; }

    /// <summary>How long the individual Graph API call took, in milliseconds.</summary>
    public long DurationMs { get; set; }

    /// <summary>Wall-clock time the operation completed (UTC).</summary>
    public DateTimeOffset TimestampUtc { get; set; } = DateTimeOffset.UtcNow;

    // ---- Factory helpers ----

    public static MigrationAuditRecord CreateMigrate(
        string b2cObjectId,
        string? eeidObjectId,
        string? eeidUpn,
        string status,
        long durationMs,
        string? errorCode = null,
        string? errorMessage = null) => new()
    {
        PartitionKey = DateTimeOffset.UtcNow.ToString("yyyyMMdd"),
        RowKey = $"migrate_{b2cObjectId}",
        B2CObjectId = b2cObjectId,
        ExternalIdObjectId = eeidObjectId,
        EEIDUpn = eeidUpn,
        Stage = "migrate",
        Status = status,
        DurationMs = durationMs,
        ErrorCode = errorCode,
        ErrorMessage = errorMessage?.Length > 4096 ? errorMessage[..4096] : errorMessage,
        TimestampUtc = DateTimeOffset.UtcNow
    };

    public static MigrationAuditRecord CreatePhone(
        string b2cObjectId,
        string? eeidUpn,
        string status,
        long durationMs,
        string? errorCode = null,
        string? errorMessage = null) => new()
    {
        PartitionKey = DateTimeOffset.UtcNow.ToString("yyyyMMdd"),
        RowKey = $"phone_{b2cObjectId}",
        B2CObjectId = b2cObjectId,
        EEIDUpn = eeidUpn,
        Stage = "phone",
        Status = status,
        DurationMs = durationMs,
        ErrorCode = errorCode,
        ErrorMessage = errorMessage?.Length > 4096 ? errorMessage[..4096] : errorMessage,
        TimestampUtc = DateTimeOffset.UtcNow
    };
}
