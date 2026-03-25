// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
using System.Threading;
using System.Threading.Tasks;

namespace B2CMigrationKit.Core.Abstractions;

/// <summary>
/// Provides access to Azure Queue Storage operations for migration orchestration.
/// </summary>
public interface IQueueClient
{
    /// <summary>
    /// Creates a queue if it does not already exist.
    /// </summary>
    Task CreateQueueIfNotExistsAsync(
        string queueName, 
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Sends a message to the specified queue.
    /// </summary>
    Task SendMessageAsync(
        string queueName, 
        string messageText, 
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Receives a message from the specified queue.
    /// </summary>
    /// <returns>A tuple containing the MessageId, PopReceipt, and MessageText, or null if empty.</returns>
    Task<(string MessageId, string PopReceipt, string MessageText)?> ReceiveMessageAsync(
        string queueName, 
        TimeSpan? visibilityTimeout = null,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Deletes a processed message from the specified queue.
    /// </summary>
    Task DeleteMessageAsync(
        string queueName, 
        string messageId, 
        string popReceipt, 
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Returns the approximate number of messages currently in the queue.
    /// The count is approximate because messages may be in-flight (invisible).
    /// </summary>
    Task<int> GetQueueLengthAsync(
        string queueName,
        CancellationToken cancellationToken = default);}