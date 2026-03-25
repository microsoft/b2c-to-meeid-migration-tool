// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
using Azure.Identity;
using Azure.Storage.Queues;
using Azure.Storage.Queues.Models;
using B2CMigrationKit.Core.Abstractions;
using B2CMigrationKit.Core.Configuration;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using System;
using System.Threading;
using System.Threading.Tasks;

namespace B2CMigrationKit.Core.Services.Infrastructure;

/// <summary>
/// Provides access to Azure Queue Storage for migration orchestration.
/// </summary>
public class QueueStorageClient : IQueueClient
{
    private readonly QueueServiceClient _serviceClient;
    private readonly ILogger<QueueStorageClient> _logger;
    private readonly StorageOptions _options;

    public QueueStorageClient(
        IOptions<StorageOptions> options,
        ILogger<QueueStorageClient> logger)
    {
        _options = options?.Value ?? throw new ArgumentNullException(nameof(options));
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));

        if (_options.UseManagedIdentity)
        {
            var credential = new DefaultAzureCredential();
            // Derive queue endpoint from configured URI (which may be a blob endpoint)
            var uri = new Uri(_options.ConnectionStringOrUri);
            var queueUri = new Uri(uri.Scheme + "://" + uri.Host.Replace(".blob.", ".queue.") + uri.AbsolutePath);
            _serviceClient = new QueueServiceClient(queueUri, credential);
            _logger.LogInformation("Queue storage client initialized with Managed Identity");
        }
        else
        {
            _serviceClient = new QueueServiceClient(_options.ConnectionStringOrUri);
            _logger.LogInformation("Queue storage client initialized with connection string");
        }
    }

    public async Task CreateQueueIfNotExistsAsync(string queueName, CancellationToken cancellationToken = default)
    {
        try
        {
            var queueClient = _serviceClient.GetQueueClient(queueName);
            await queueClient.CreateIfNotExistsAsync(cancellationToken: cancellationToken);
            _logger.LogInformation("Ensured queue exists: {QueueName}", queueName);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to ensure queue exists: {QueueName}", queueName);
            throw;
        }
    }

    public async Task SendMessageAsync(string queueName, string messageText, CancellationToken cancellationToken = default)
    {
        try
        {
            var queueClient = _serviceClient.GetQueueClient(queueName);
            await queueClient.SendMessageAsync(messageText, cancellationToken: cancellationToken);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to send message to queue: {QueueName}", queueName);
            throw;
        }
    }

    public async Task<(string MessageId, string PopReceipt, string MessageText)?> ReceiveMessageAsync(
        string queueName, 
        TimeSpan? visibilityTimeout = null,
        CancellationToken cancellationToken = default)
    {
        try
        {
            var queueClient = _serviceClient.GetQueueClient(queueName);
            QueueMessage[] messages = await queueClient.ReceiveMessagesAsync(maxMessages: 1, visibilityTimeout: visibilityTimeout, cancellationToken: cancellationToken);

            if (messages != null && messages.Length > 0)
            {
                var message = messages[0];
                return (message.MessageId, message.PopReceipt, message.MessageText);
            }

            return null;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to receive message from queue: {QueueName}", queueName);
            throw;
        }
    }

    public async Task DeleteMessageAsync(string queueName, string messageId, string popReceipt, CancellationToken cancellationToken = default)
    {
        try
        {
            var queueClient = _serviceClient.GetQueueClient(queueName);
            await queueClient.DeleteMessageAsync(messageId, popReceipt, cancellationToken);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to delete message {MessageId} from queue: {QueueName}", messageId, queueName);
            throw;
        }
    }

    public async Task<int> GetQueueLengthAsync(string queueName, CancellationToken cancellationToken = default)
    {
        try
        {
            var queueClient = _serviceClient.GetQueueClient(queueName);
            var properties = await queueClient.GetPropertiesAsync(cancellationToken);
            return properties.Value.ApproximateMessagesCount;
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Could not get queue length for {QueueName}", queueName);
            return -1;
        }
    }
}
