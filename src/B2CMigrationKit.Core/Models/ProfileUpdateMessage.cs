// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
namespace B2CMigrationKit.Core.Models;

/// <summary>
/// Represents a profile update message for queue-based async sync.
/// </summary>
public class ProfileUpdateMessage
{
    /// <summary>
    /// Gets or sets the unique message ID.
    /// </summary>
    public string? MessageId { get; set; }

    /// <summary>
    /// Gets or sets the pop receipt (used for message deletion).
    /// </summary>
    public string? PopReceipt { get; set; }

    /// <summary>
    /// Gets or sets the source system where the change originated.
    /// </summary>
    public UpdateSource Source { get; set; }

    /// <summary>
    /// Gets or sets the user's ID in the source system.
    /// </summary>
    public string? UserId { get; set; }

    /// <summary>
    /// Gets or sets the user's ID in the target system (if known).
    /// </summary>
    public string? TargetUserId { get; set; }

    /// <summary>
    /// Gets or sets the B2C object ID for correlation.
    /// </summary>
    public string? B2CObjectId { get; set; }

    /// <summary>
    /// Gets or sets the user principal name.
    /// </summary>
    public string? UserPrincipalName { get; set; }

    /// <summary>
    /// Gets or sets the properties that were updated.
    /// </summary>
    public Dictionary<string, object> UpdatedProperties { get; set; } = new();

    /// <summary>
    /// Gets or sets the timestamp when the update occurred.
    /// </summary>
    public DateTimeOffset Timestamp { get; set; } = DateTimeOffset.UtcNow;

    /// <summary>
    /// Gets or sets the correlation ID for tracking.
    /// </summary>
    public string? CorrelationId { get; set; }
}

/// <summary>
/// Specifies the source system for a profile update.
/// </summary>
public enum UpdateSource
{
    /// <summary>
    /// Update originated from Azure AD B2C.
    /// </summary>
    B2C,

    /// <summary>
    /// Update originated from Entra External ID.
    /// </summary>
    ExternalId
}
