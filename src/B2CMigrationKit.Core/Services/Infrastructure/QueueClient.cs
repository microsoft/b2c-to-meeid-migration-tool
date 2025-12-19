// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
using Azure.Identity;
using Azure.Storage.Queues;
using Azure.Storage.Queues.Models;
using B2CMigrationKit.Core.Abstractions;
using B2CMigrationKit.Core.Configuration;
using B2CMigrationKit.Core.Models;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using System.Text.Json;

namespace B2CMigrationKit.Core.Services.Infrastructure;

/// <summary>
/// Provides access to Azure Queue Storage for async profile sync.
/// </summary>
public class QueueClient : IQueueClient
{
    private readonly QueueServiceClient _serviceClient;
    private readonly ILogger<QueueClient> _logger;
    private readonly StorageOptions _options;

    public QueueClient(
        IOptions<StorageOptions> options,
        ILogger<QueueClient> logger)
    {
        _options = options?.Value ?? throw new ArgumentNullException(nameof(options));
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));

        if (_options.UseManagedIdentity)
        {
            var credential = new DefaultAzureCredential();
            var serviceUri = new Uri(_options.ConnectionStringOrUri.Replace("blob", "queue"));
            _serviceClient = new QueueServiceClient(serviceUri, credential);
            _logger.LogInformation("Queue client initialized with Managed Identity");
        }
        else
        {
            _serviceClient = new QueueServiceClient(_options.ConnectionStringOrUri);
            _logger.LogInformation("Queue client initialized with connection string");
        }
    }

    public async Task SendMessageAsync(
        string queueName,
        ProfileUpdateMessage message,
        CancellationToken cancellationToken = default)
    {
        try
        {
            var queueClient = _serviceClient.GetQueueClient(queueName);
            var json = JsonSerializer.Serialize(message);

            await queueClient.SendMessageAsync(json, cancellationToken);

            _logger.LogInformation("Sent profile update message to queue {Queue} for user {UserId}",
                queueName, message.UserId);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to send message to queue {Queue}", queueName);
            throw;
        }
    }

    public async Task<IEnumerable<ProfileUpdateMessage>> ReceiveMessagesAsync(
        string queueName,
        int maxMessages = 1,
        CancellationToken cancellationToken = default)
    {
        try
        {
            var queueClient = _serviceClient.GetQueueClient(queueName);
            var response = await queueClient.ReceiveMessagesAsync(maxMessages, cancellationToken: cancellationToken);

            var messages = new List<ProfileUpdateMessage>();

            foreach (var queueMessage in response.Value)
            {
                try
                {
                    var message = JsonSerializer.Deserialize<ProfileUpdateMessage>(queueMessage.MessageText);
                    if (message != null)
                    {
                        message.MessageId = queueMessage.MessageId;
                        message.PopReceipt = queueMessage.PopReceipt;
                        messages.Add(message);
                    }
                }
                catch (JsonException ex)
                {
                    _logger.LogError(ex, "Failed to deserialize message {MessageId}", queueMessage.MessageId);
                }
            }

            _logger.LogInformation("Received {Count} messages from queue {Queue}",
                messages.Count, queueName);

            return messages;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to receive messages from queue {Queue}", queueName);
            throw;
        }
    }

    public async Task DeleteMessageAsync(
        string queueName,
        string messageId,
        string popReceipt,
        CancellationToken cancellationToken = default)
    {
        try
        {
            var queueClient = _serviceClient.GetQueueClient(queueName);
            await queueClient.DeleteMessageAsync(messageId, popReceipt, cancellationToken);

            _logger.LogDebug("Deleted message {MessageId} from queue {Queue}", messageId, queueName);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to delete message {MessageId} from queue {Queue}",
                messageId, queueName);
            throw;
        }
    }

    public async Task EnsureQueueExistsAsync(
        string queueName,
        CancellationToken cancellationToken = default)
    {
        try
        {
            var queueClient = _serviceClient.GetQueueClient(queueName);
            await queueClient.CreateIfNotExistsAsync(cancellationToken: cancellationToken);

            _logger.LogInformation("Ensured queue exists: {Queue}", queueName);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to ensure queue exists: {Queue}", queueName);
            throw;
        }
    }
}
