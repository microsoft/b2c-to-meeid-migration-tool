// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
using B2CMigrationKit.Core.Abstractions;
using B2CMigrationKit.Core.Configuration;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using Microsoft.Graph;
using Polly;
using Polly.Retry;
using System.Net;
using GraphModels = Microsoft.Graph.Models;
using CoreModels = B2CMigrationKit.Core.Models;

namespace B2CMigrationKit.Core.Services.Infrastructure;

/// <summary>
/// Microsoft Graph client with retry logic and throttling handling.
/// </summary>
public class GraphClient : IGraphClient
{
    private readonly GraphServiceClient _client;
    private readonly ILogger<GraphClient> _logger;
    private readonly ITelemetryService _telemetry;
    private readonly RetryOptions _retryOptions;
    private readonly ResiliencePipeline _retryPipeline;

    public GraphClient(
        GraphServiceClient client,
        IOptions<RetryOptions> retryOptions,
        ILogger<GraphClient> logger,
        ITelemetryService telemetry)
    {
        _client = client ?? throw new ArgumentNullException(nameof(client));
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
        _telemetry = telemetry ?? throw new ArgumentNullException(nameof(telemetry));
        _retryOptions = retryOptions?.Value ?? throw new ArgumentNullException(nameof(retryOptions));

        _retryPipeline = CreateRetryPipeline();
    }

    private ResiliencePipeline CreateRetryPipeline()
    {
        return new ResiliencePipelineBuilder()
            .AddRetry(new RetryStrategyOptions
            {
                MaxRetryAttempts = _retryOptions.MaxRetries,
                Delay = TimeSpan.FromMilliseconds(_retryOptions.InitialDelayMs),
                BackoffType = DelayBackoffType.Exponential,
                UseJitter = true,
                OnRetry = args =>
                {
                    _logger.LogWarning("Retry attempt {Attempt} after {Delay}ms due to: {Exception}",
                        args.AttemptNumber, args.RetryDelay.TotalMilliseconds, args.Outcome.Exception?.Message);
                    _telemetry.IncrementCounter("GraphClient.Retries");
                    return ValueTask.CompletedTask;
                }
            })
            .AddTimeout(TimeSpan.FromSeconds(_retryOptions.OperationTimeoutSeconds))
            .Build();
    }

    public async Task<CoreModels.PagedResult<CoreModels.UserProfile>> GetUsersAsync(
        int pageSize = 100,
        string? select = null,
        string? filter = null,
        string? skipToken = null,
        CancellationToken cancellationToken = default)
    {
        return await _retryPipeline.ExecuteAsync(async ct =>
        {
            var request = _client.Users.GetAsync(config =>
            {
                config.QueryParameters.Top = pageSize;
                config.QueryParameters.Count = true;

                if (!string.IsNullOrEmpty(select))
                {
                    config.QueryParameters.Select = select.Split(',');
                }

                if (!string.IsNullOrEmpty(filter))
                {
                    config.QueryParameters.Filter = filter;
                }

                // Skip token is handled via OData next link
                // Graph SDK 5.x handles continuation automatically
            }, ct);

            var response = await request;

            var users = response?.Value?.Select(MapToUserProfile).ToList() ?? new List<CoreModels.UserProfile>();
            var nextPageToken = response?.OdataNextLink != null
                ? ExtractSkipToken(response.OdataNextLink)
                : null;

            _telemetry.IncrementCounter("GraphClient.GetUsers", users.Count);

            return new CoreModels.PagedResult<CoreModels.UserProfile>
            {
                Items = users,
                NextPageToken = nextPageToken
            };
        }, cancellationToken);
    }

    public async Task<CoreModels.UserProfile> CreateUserAsync(
        CoreModels.UserProfile user,
        CancellationToken cancellationToken = default)
    {
        return await _retryPipeline.ExecuteAsync(async ct =>
        {
            var graphUser = MapToGraphUser(user);
            var created = await _client.Users.PostAsync(graphUser, cancellationToken: ct);

            _telemetry.IncrementCounter("GraphClient.UserCreated");

            return MapToUserProfile(created!);
        }, cancellationToken);
    }

    public async Task<CoreModels.BatchResult> CreateUsersBatchAsync(
        IEnumerable<CoreModels.UserProfile> users,
        CancellationToken cancellationToken = default)
    {
        var result = new CoreModels.BatchResult
        {
            TotalItems = users.Count()
        };

        var batches = users.Chunk(20); // Graph API batch limit is 20

        foreach (var batch in batches)
        {
            try
            {
                var batchRequest = new Microsoft.Graph.BatchRequestContentCollection(_client);
                var requestIdToUser = new Dictionary<string, CoreModels.UserProfile>();

                foreach (var user in batch)
                {
                    var graphUser = MapToGraphUser(user);
                    var requestInfo = _client.Users.ToPostRequestInformation(graphUser);
                    var requestId = await batchRequest.AddBatchRequestStepAsync(requestInfo);
                    requestIdToUser[requestId] = user;
                }

                var batchResponse = await _client.Batch.PostAsync(batchRequest, cancellationToken: cancellationToken);

                // Check individual responses
                var successCount = 0;
                var failureCount = 0;
                var skippedCount = 0;

                foreach (var requestId in requestIdToUser.Keys)
                {
                    try
                    {
                        var response = await batchResponse.GetResponseByIdAsync(requestId);
                        var user = requestIdToUser[requestId];

                        if (response != null && response.IsSuccessStatusCode)
                        {
                            successCount++;
                        }
                        else
                        {
                            var statusCode = response?.StatusCode ?? HttpStatusCode.InternalServerError;
                            var errorContent = response != null ? await response.Content.ReadAsStringAsync() : "No response";

                            // Check if this is a duplicate user (ObjectConflict)
                            if (statusCode == HttpStatusCode.BadRequest &&
                                errorContent.Contains("ObjectConflict") &&
                                (errorContent.Contains("userPrincipalName already exists") ||
                                 errorContent.Contains("Another object with the same value")))
                            {
                                skippedCount++;
                                result.SkippedUserIds.Add(user.UserPrincipalName ?? user.Id ?? "unknown");
                                result.DuplicateUsers.Add(user); // Store for potential extension attribute update
                                _logger.LogInformation("User {UPN} already exists, skipping (RequestId: {RequestId})",
                                    user.UserPrincipalName, requestId);
                            }
                            else
                            {
                                failureCount++;
                                _logger.LogWarning("User creation failed (UPN: {UPN}, RequestId: {RequestId}, Status: {Status}): {Error}",
                                    user.UserPrincipalName, requestId, statusCode, errorContent);
                            }
                        }
                    }
                    catch (Exception ex)
                    {
                        failureCount++;
                        var user = requestIdToUser[requestId];
                        _logger.LogWarning(ex, "Failed to get batch response for UPN: {UPN}, RequestId: {RequestId}",
                            user.UserPrincipalName, requestId);
                    }
                }

                result.SuccessCount += successCount;
                result.FailureCount += failureCount;
                result.SkippedCount += skippedCount;

                _logger.LogInformation("Batch completed: {Success} succeeded, {Skipped} skipped (duplicates), {Failed} failed",
                    successCount, skippedCount, failureCount);

                if (successCount > 0)
                {
                    _telemetry.IncrementCounter("GraphClient.UserCreatedBatch", successCount);
                }
            }
            catch (Exception ex)
            {
                result.FailureCount += batch.Count();
                _logger.LogError(ex, "Batch create failed for {Count} users", batch.Count());
            }
        }

        return result;
    }

    public async Task UpdateUserAsync(
        string userId,
        Dictionary<string, object> updates,
        CancellationToken cancellationToken = default)
    {
        await _retryPipeline.ExecuteAsync(async ct =>
        {
            var user = new GraphModels.User
            {
                AdditionalData = updates
            };

            await _client.Users[userId].PatchAsync(user, cancellationToken: ct);

            _telemetry.IncrementCounter("GraphClient.UserUpdated");
        }, cancellationToken);
    }

    public async Task<CoreModels.UserProfile?> GetUserByIdAsync(
        string userId,
        string? select = null,
        CancellationToken cancellationToken = default)
    {
        return await _retryPipeline.ExecuteAsync(async ct =>
        {
            var request = _client.Users[userId].GetAsync(config =>
            {
                if (!string.IsNullOrEmpty(select))
                {
                    config.QueryParameters.Select = select.Split(',');
                }
            }, ct);

            var user = await request;

            return user != null ? MapToUserProfile(user) : null;
        }, cancellationToken);
    }

    public async Task<CoreModels.UserProfile?> FindUserByExtensionAttributeAsync(
        string extensionAttributeName,
        string value,
        CancellationToken cancellationToken = default)
    {
        var filter = $"{extensionAttributeName} eq '{value}'";
        var result = await GetUsersAsync(pageSize: 1, filter: filter, cancellationToken: cancellationToken);

        return result.Items.FirstOrDefault();
    }

    public async Task SetUserPasswordAsync(
        string userId,
        string password,
        bool forceChangePasswordNextSignIn = false,
        CancellationToken cancellationToken = default)
    {
        await _retryPipeline.ExecuteAsync(async ct =>
        {
            var user = new GraphModels.User
            {
                PasswordProfile = new GraphModels.PasswordProfile
                {
                    ForceChangePasswordNextSignIn = forceChangePasswordNextSignIn,
                    Password = password
                }
            };

            await _client.Users[userId].PatchAsync(user, cancellationToken: ct);

            _telemetry.IncrementCounter("GraphClient.PasswordSet");
        }, cancellationToken);
    }

    private CoreModels.UserProfile MapToUserProfile(GraphModels.User user)
    {
        var profile = new CoreModels.UserProfile
        {
            Id = user.Id,
            UserPrincipalName = user.UserPrincipalName,
            DisplayName = user.DisplayName,
            GivenName = user.GivenName,
            Surname = user.Surname,
            Mail = user.Mail,
            MobilePhone = user.MobilePhone,
            StreetAddress = user.StreetAddress,
            City = user.City,
            State = user.State,
            PostalCode = user.PostalCode,
            Country = user.Country,
            AccountEnabled = user.AccountEnabled ?? true,
            CreatedDateTime = user.CreatedDateTime
        };

        if (user.OtherMails != null)
        {
            profile.OtherMails = user.OtherMails.ToList();
        }

        if (user.Identities != null)
        {
            profile.Identities = user.Identities.Select(i => new CoreModels.ObjectIdentity
            {
                SignInType = i.SignInType,
                Issuer = i.Issuer,
                IssuerAssignedId = i.IssuerAssignedId
            }).ToList();
        }

        if (user.AdditionalData != null)
        {
            profile.ExtensionAttributes = new Dictionary<string, object>(user.AdditionalData);
        }

        return profile;
    }

    private GraphModels.User MapToGraphUser(CoreModels.UserProfile profile)
    {
        var user = new GraphModels.User
        {
            UserPrincipalName = profile.UserPrincipalName,
            DisplayName = profile.DisplayName,
            GivenName = profile.GivenName,
            Surname = profile.Surname,
            Mail = profile.Mail,
            MobilePhone = profile.MobilePhone,
            StreetAddress = profile.StreetAddress,
            City = profile.City,
            State = profile.State,
            PostalCode = profile.PostalCode,
            Country = profile.Country,
            AccountEnabled = profile.AccountEnabled,
            OtherMails = profile.OtherMails,
            UserType = "Member", // Required for External ID
            PasswordProfile = profile.PasswordProfile != null ? new GraphModels.PasswordProfile
            {
                ForceChangePasswordNextSignIn = profile.PasswordProfile.ForceChangePasswordNextSignIn,
                Password = profile.PasswordProfile.Password
            } : null
        };

        if (profile.Identities.Any())
        {
            user.Identities = profile.Identities.Select(i => new GraphModels.ObjectIdentity
            {
                SignInType = i.SignInType,
                Issuer = i.Issuer,
                IssuerAssignedId = i.IssuerAssignedId
            }).ToList();
        }

        if (profile.ExtensionAttributes.Any())
        {
            user.AdditionalData = new Dictionary<string, object>(profile.ExtensionAttributes);
        }

        return user;
    }

    private string? ExtractSkipToken(string nextLink)
    {
        // Extract $skiptoken from the URL
        var tokenParam = "$skiptoken=";
        var tokenIndex = nextLink.IndexOf(tokenParam, StringComparison.OrdinalIgnoreCase);
        if (tokenIndex == -1) return null;

        var tokenStart = tokenIndex + tokenParam.Length;
        var tokenEnd = nextLink.IndexOf('&', tokenStart);

        return tokenEnd == -1
            ? Uri.UnescapeDataString(nextLink.Substring(tokenStart))
            : Uri.UnescapeDataString(nextLink.Substring(tokenStart, tokenEnd - tokenStart));
    }
}
