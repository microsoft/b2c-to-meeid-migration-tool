// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
using System;
using System.Collections.Generic;

namespace B2CMigrationKit.Core.Models;

/// <summary>
/// Represents a chunk of user IDs dispatched to the queue by the Master for a Worker to process.
/// </summary>
public class ExportJobMessage
{
    /// <summary>
    /// Gets or sets a unique identifier for the chunk.
    /// </summary>
    public string JobId { get; set; } = Guid.NewGuid().ToString();

    /// <summary>
    /// Gets or sets the list of Microsoft Graph Object IDs to fetch in this batch.
    /// </summary>
    public List<string> UserIds { get; set; } = new List<string>();

    /// <summary>
    /// Gets or sets the time this job was created.
    /// </summary>
    public DateTimeOffset CreatedAt { get; set; } = DateTimeOffset.UtcNow;
}
