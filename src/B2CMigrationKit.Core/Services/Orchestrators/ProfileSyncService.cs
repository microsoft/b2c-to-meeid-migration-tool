// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
using B2CMigrationKit.Core.Abstractions;
using B2CMigrationKit.Core.Configuration;
using B2CMigrationKit.Core.Models;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace B2CMigrationKit.Core.Services.Orchestrators;

/// <summary>
/// Handles asynchronous profile synchronization between B2C and External ID.
/// </summary>
public class ProfileSyncService
{
    private readonly IGraphClient _b2cGraphClient;
    private readonly IGraphClient _externalIdGraphClient;
    private readonly IQueueClient _queueClient;
    private readonly ITelemetryService _telemetry;
    private readonly ILogger<ProfileSyncService> _logger;
    private readonly MigrationOptions _options;

    public ProfileSyncService(
        IQueueClient queueClient,
        ITelemetryService telemetry,
        IOptions<MigrationOptions> options,
        ILogger<ProfileSyncService> logger)
    {
        _queueClient = queueClient ?? throw new ArgumentNullException(nameof(queueClient));
        _telemetry = telemetry ?? throw new ArgumentNullException(nameof(telemetry));
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
        _options = options?.Value ?? throw new ArgumentNullException(nameof(options));
    }

    /// <summary>
    /// Queues a profile update message for async processing.
    /// </summary>
    public async Task QueueProfileUpdateAsync(
        ProfileUpdateMessage message,
        CancellationToken cancellationToken = default)
    {
        try
        {
            await _queueClient.SendMessageAsync(
                _options.Storage.ProfileSyncQueueName,
                message,
                cancellationToken);

            _logger.LogInformation("Queued profile update for user {UserId} from {Source}",
                message.UserId, message.Source);

            _telemetry.IncrementCounter("ProfileSync.MessagesQueued");
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to queue profile update for user {UserId}", message.UserId);
            _telemetry.TrackException(ex);
            throw;
        }
    }

    /// <summary>
    /// Processes a profile update message from the queue.
    /// </summary>
    public async Task<bool> ProcessProfileUpdateAsync(
        ProfileUpdateMessage message,
        IGraphClient sourceClient,
        IGraphClient targetClient,
        CancellationToken cancellationToken = default)
    {
        try
        {
            _logger.LogInformation("Processing profile update for user {UserId} from {Source}",
                message.UserId, message.Source);

            // Find target user
            UserProfile? targetUser = null;

            if (!string.IsNullOrEmpty(message.TargetUserId))
            {
                targetUser = await targetClient.GetUserByIdAsync(
                    message.TargetUserId,
                    cancellationToken: cancellationToken);
            }
            else if (!string.IsNullOrEmpty(message.B2CObjectId))
            {
                // Find by B2C object ID extension attribute
                var attrName = MigrationExtensionAttributes.GetFullAttributeName(
                    _options.ExternalId.ExtensionAppId,
                    MigrationExtensionAttributes.B2CObjectId);

                targetUser = await targetClient.FindUserByExtensionAttributeAsync(
                    attrName,
                    message.B2CObjectId,
                    cancellationToken);
            }

            if (targetUser == null)
            {
                _logger.LogWarning("Target user not found for sync operation: {UserId}", message.UserId);
                return false;
            }

            // Apply updates
            if (message.UpdatedProperties.Any())
            {
                await targetClient.UpdateUserAsync(
                    targetUser.Id!,
                    message.UpdatedProperties,
                    cancellationToken);

                _logger.LogInformation("Synced {Count} properties for user {UserId}",
                    message.UpdatedProperties.Count, targetUser.Id);

                _telemetry.IncrementCounter("ProfileSync.UpdatesApplied");
            }

            return true;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to process profile update for user {UserId}", message.UserId);
            _telemetry.TrackException(ex);
            return false;
        }
    }

    /// <summary>
    /// Polls the queue and processes profile update messages.
    /// </summary>
    public async Task ProcessQueueAsync(
        IGraphClient b2cClient,
        IGraphClient externalIdClient,
        int maxMessages = 10,
        CancellationToken cancellationToken = default)
    {
        try
        {
            var messages = await _queueClient.ReceiveMessagesAsync(
                _options.Storage.ProfileSyncQueueName,
                maxMessages,
                cancellationToken);

            foreach (var message in messages)
            {
                bool success;

                if (message.Source == UpdateSource.B2C)
                {
                    // Sync from B2C to External ID
                    success = await ProcessProfileUpdateAsync(
                        message,
                        b2cClient,
                        externalIdClient,
                        cancellationToken);
                }
                else
                {
                    // Sync from External ID to B2C
                    success = await ProcessProfileUpdateAsync(
                        message,
                        externalIdClient,
                        b2cClient,
                        cancellationToken);
                }

                // Delete message from queue if processed successfully
                if (success && !string.IsNullOrEmpty(message.MessageId))
                {
                    await _queueClient.DeleteMessageAsync(
                        _options.Storage.ProfileSyncQueueName,
                        message.MessageId,
                        message.PopReceipt!,
                        cancellationToken);
                }
            }

            _logger.LogInformation("Processed {Count} profile sync messages", messages.Count());
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error processing profile sync queue");
            _telemetry.TrackException(ex);
        }
    }
}
