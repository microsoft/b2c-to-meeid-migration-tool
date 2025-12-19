// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
using B2CMigrationKit.Core.Models;

namespace B2CMigrationKit.Core.Abstractions;

/// <summary>
/// Provides access to Azure Queue operations for async profile sync.
/// </summary>
public interface IQueueClient
{
    /// <summary>
    /// Sends a profile update message to the queue.
    /// </summary>
    /// <param name="queueName">The queue name.</param>
    /// <param name="message">The profile update message.</param>
    /// <param name="cancellationToken">Token to cancel the operation.</param>
    Task SendMessageAsync(
        string queueName,
        ProfileUpdateMessage message,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Receives messages from the queue.
    /// </summary>
    /// <param name="queueName">The queue name.</param>
    /// <param name="maxMessages">Maximum number of messages to receive.</param>
    /// <param name="cancellationToken">Token to cancel the operation.</param>
    /// <returns>Collection of profile update messages.</returns>
    Task<IEnumerable<ProfileUpdateMessage>> ReceiveMessagesAsync(
        string queueName,
        int maxMessages = 1,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Deletes a message from the queue after successful processing.
    /// </summary>
    /// <param name="queueName">The queue name.</param>
    /// <param name="messageId">The message ID.</param>
    /// <param name="popReceipt">The pop receipt from the received message.</param>
    /// <param name="cancellationToken">Token to cancel the operation.</param>
    Task DeleteMessageAsync(
        string queueName,
        string messageId,
        string popReceipt,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Ensures a queue exists, creating it if necessary.
    /// </summary>
    /// <param name="queueName">The queue name.</param>
    /// <param name="cancellationToken">Token to cancel the operation.</param>
    Task EnsureQueueExistsAsync(
        string queueName,
        CancellationToken cancellationToken = default);
}
