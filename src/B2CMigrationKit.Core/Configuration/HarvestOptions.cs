// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
using System.ComponentModel.DataAnnotations;

namespace B2CMigrationKit.Core.Configuration;

/// <summary>
/// Configuration options for the Harvest (Master/Producer) phase.
///
/// The master performs a single, extremely fast pass through all B2C users
/// requesting ONLY the 'id' field (up to 999 per page). It groups the IDs
/// into batches of <see cref="IdsPerMessage"/> and enqueues each batch as one
/// Azure Queue message (JSON array of strings).
///
/// <c>worker-migrate</c> instances dequeue these messages independently,
/// resolve full user profiles via the Graph $batch API, create users in
/// Entra External ID, and enqueue phone-registration tasks — all without
/// any file I/O or inter-process coordination.
/// </summary>
public class HarvestOptions
{
    /// <summary>
    /// Gets or sets the Azure Queue name where user-ID batches will be enqueued.
    /// All <c>worker-migrate</c> instances must point to the same queue.
    /// Default: "user-ids-to-process"
    /// </summary>
    public string QueueName { get; set; } = "user-ids-to-process";

    /// <summary>
    /// Gets or sets how many user IDs to pack into each queue message.
    /// Keep at 20 (the Graph $batch limit) so each worker can resolve one
    /// message with a single $batch call. Default: 20.
    /// </summary>
    [Range(1, 20)]
    public int IdsPerMessage { get; set; } = 20;

    /// <summary>
    /// Gets or sets the page size used when fetching user IDs from B2C.
    /// B2C supports up to 999 when selecting only 'id'. Default: 999.
    /// </summary>
    [Range(1, 999)]
    public int PageSize { get; set; } = 999;

    /// <summary>
    /// Gets or sets the message visibility timeout for worker processing.
    /// If a worker does not delete the message within this time the message
    /// becomes visible again and another worker can retry it.
    /// Default: 30 minutes (covers worst-case retry storms on large batches).
    /// </summary>
    public TimeSpan MessageVisibilityTimeout { get; set; } = TimeSpan.FromMinutes(30);

    /// <summary>
    /// Gets or sets the maximum number of user IDs to harvest. 0 = unlimited (harvest all users).
    /// Use a small value (e.g. 20) for local smoke-tests so only a limited number
    /// of queue messages are produced and worker-migrate exits quickly.
    /// </summary>
    [Range(0, int.MaxValue)]
    public int MaxUsers { get; set; } = 0;
}
