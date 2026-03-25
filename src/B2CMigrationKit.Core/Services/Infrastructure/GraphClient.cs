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
    // Identifies which tenant this client targets; included in every throttle log/event.
    private readonly string _tenantRole;

    public GraphClient(
        GraphServiceClient client,
        IOptions<RetryOptions> retryOptions,
        ILogger<GraphClient> logger,
        ITelemetryService telemetry,
        string tenantRole = "unknown")
    {
        _client = client ?? throw new ArgumentNullException(nameof(client));
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
        _telemetry = telemetry ?? throw new ArgumentNullException(nameof(telemetry));
        _retryOptions = retryOptions?.Value ?? throw new ArgumentNullException(nameof(retryOptions));
        _tenantRole = tenantRole;

        _retryPipeline = CreateRetryPipeline();
    }

    // HTTP status codes that are deterministic failures — retrying will never help.
    private static readonly HashSet<int> _nonRetryableStatusCodes = new()
    {
        400, // Bad Request
        401, // Unauthorized
        403, // Forbidden
        404, // Not Found
        405, // Method Not Allowed
        409, // Conflict (duplicate)
        422, // Unprocessable Entity
    };

    private ResiliencePipeline CreateRetryPipeline()
    {
        return new ResiliencePipelineBuilder()
            .AddRetry(new RetryStrategyOptions
            {
                MaxRetryAttempts = _retryOptions.MaxRetries,
                Delay = TimeSpan.FromMilliseconds(_retryOptions.InitialDelayMs),
                BackoffType = DelayBackoffType.Exponential,
                UseJitter = true,
                ShouldHandle = args =>
                {
                    // Never retry deterministic failures — they will always fail the same way.
                    if (args.Outcome.Exception is Microsoft.Graph.Models.ODataErrors.ODataError odataError
                        && _nonRetryableStatusCodes.Contains(odataError.ResponseStatusCode))
                    {
                        return ValueTask.FromResult(false);
                    }

                    return ValueTask.FromResult(args.Outcome.Exception is not null);
                },
                // Honor the Retry-After header when the server sends one (typically on 429).
                DelayGenerator = args =>
                {
                    if (_retryOptions.UseRetryAfterHeader
                        && args.Outcome.Exception is Microsoft.Graph.Models.ODataErrors.ODataError throttleError
                        && throttleError.ResponseStatusCode == 429
                        && throttleError.ResponseHeaders.TryGetValue("Retry-After", out var values))
                    {
                        var raw = values.FirstOrDefault();
                        if (int.TryParse(raw, out var seconds))
                        {
                            return new ValueTask<TimeSpan?>(TimeSpan.FromSeconds(seconds));
                        }
                    }
                    // Return null → Polly falls back to exponential backoff + jitter.
                    return new ValueTask<TimeSpan?>((TimeSpan?)null);
                },
                OnRetry = args =>
                {
                    var isThrottle = args.Outcome.Exception is Microsoft.Graph.Models.ODataErrors.ODataError odataErr
                        && odataErr.ResponseStatusCode == 429;

                    // Read Retry-After header value for logging (may be absent).
                    string? retryAfterRaw = null;
                    if (args.Outcome.Exception is Microsoft.Graph.Models.ODataErrors.ODataError hdrErr
                        && hdrErr.ResponseHeaders.TryGetValue("Retry-After", out var hdrValues))
                    {
                        retryAfterRaw = hdrValues.FirstOrDefault();
                    }

                    if (isThrottle)
                    {
                        _logger.LogWarning(
                            "[THROTTLE] tenant={TenantRole} attempt={Attempt} delayMs={DelayMs} retryAfterHeader={RetryAfter}",
                            _tenantRole, args.AttemptNumber + 1,
                            (int)args.RetryDelay.TotalMilliseconds, retryAfterRaw ?? "none");

                        _telemetry.TrackEvent("Graph.Throttled", new Dictionary<string, string>
                        {
                            ["tenantRole"]     = _tenantRole,
                            ["attempt"]        = (args.AttemptNumber + 1).ToString(),
                            ["delayMs"]        = ((int)args.RetryDelay.TotalMilliseconds).ToString(),
                            ["retryAfterMs"]   = retryAfterRaw != null && int.TryParse(retryAfterRaw, out var s)
                                                    ? (s * 1000).ToString() : "none",
                            ["ts"]             = DateTimeOffset.UtcNow.ToString("o")
                        });
                        _telemetry.IncrementCounter("GraphClient.Throttled");
                    }
                    else
                    {
                        _logger.LogWarning(
                            "[RETRY] tenant={TenantRole} attempt={Attempt} delayMs={DelayMs} error={Error}",
                            _tenantRole, args.AttemptNumber + 1,
                            (int)args.RetryDelay.TotalMilliseconds, args.Outcome.Exception?.Message);
                    }

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
            GraphModels.UserCollectionResponse? response;

            // If we have a nextLink (full URL), use it directly for pagination
            if (!string.IsNullOrEmpty(skipToken) && skipToken.StartsWith("http", StringComparison.OrdinalIgnoreCase))
            {
                // Use the full OData nextLink URL for pagination
                var requestInfo = new Microsoft.Kiota.Abstractions.RequestInformation
                {
                    HttpMethod = Microsoft.Kiota.Abstractions.Method.GET,
                    URI = new Uri(skipToken)
                };
                requestInfo.Headers.Add("ConsistencyLevel", "eventual");
                
                response = await _client.RequestAdapter.SendAsync(
                    requestInfo, 
                    GraphModels.UserCollectionResponse.CreateFromDiscriminatorValue, 
                    cancellationToken: ct);
            }
            else
            {
                // First page request - build query parameters
                response = await _client.Users.GetAsync(config =>
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

                    config.Headers.Add("ConsistencyLevel", "eventual");
                }, ct);
            }

            var users = response?.Value?.Select(MapToUserProfile).ToList() ?? new List<CoreModels.UserProfile>();
            
            // Return the full nextLink URL as the token for next page
            var nextPageToken = response?.OdataNextLink;

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

    public async Task<IReadOnlyList<CoreModels.UserProfile>> GetUsersByIdsAsync(
        IEnumerable<string> userIds,
        string? select = null,
        CancellationToken cancellationToken = default)
    {
        var idList = userIds.ToList();
        if (idList.Count == 0)
        {
            return Array.Empty<CoreModels.UserProfile>();
        }

        // Graph $batch is limited to 20 requests per call.
        if (idList.Count > 20)
        {
            throw new ArgumentException("GetUsersByIdsAsync supports at most 20 user IDs per call. " +
                "Chunk the list before calling this method.", nameof(userIds));
        }

        return await _retryPipeline.ExecuteAsync(async ct =>
        {
            var results = new List<CoreModels.UserProfile>(idList.Count);

            var batchRequest = new Microsoft.Graph.BatchRequestContentCollection(_client);
            var requestIdToUserId = new Dictionary<string, string>(idList.Count);

            foreach (var userId in idList)
            {
                // Build a GET /users/{id} request, optionally with $select
                var requestInfo = _client.Users[userId].ToGetRequestInformation(config =>
                {
                    if (!string.IsNullOrEmpty(select))
                    {
                        config.QueryParameters.Select = select.Split(',');
                    }
                });

                var requestId = await batchRequest.AddBatchRequestStepAsync(requestInfo);
                requestIdToUserId[requestId] = userId;
            }

            var batchResponse = await _client.Batch.PostAsync(batchRequest, cancellationToken: ct);

            foreach (var (requestId, userId) in requestIdToUserId)
            {
                try
                {
                    var user = await batchResponse.GetResponseByIdAsync<GraphModels.User>(requestId);
                    if (user != null)
                    {
                        results.Add(MapToUserProfile(user));
                    }
                }
                catch (Exception ex)
                {
                    _logger.LogWarning(ex,
                        "Failed to retrieve user {UserId} in batch request {RequestId}", userId, requestId);
                }
            }

            _telemetry.IncrementCounter("GraphClient.GetUsersByIds", results.Count);

            return (IReadOnlyList<CoreModels.UserProfile>)results;
        }, cancellationToken);
    }

    public async Task<string?> GetMfaPhoneNumberAsync(
        string userId,
        CancellationToken cancellationToken = default)
    {
        // Fixed GUID for the mobile phone authentication method type.
        // Source: https://learn.microsoft.com/en-us/graph/api/phoneauthenticationmethod-get
        const string MobilePhoneMethodId = "3179e48a-750b-4051-897c-87b9720928f7";

        return await _retryPipeline.ExecuteAsync(async ct =>
        {
            try
            {
                var method = await _client.Users[userId]
                    .Authentication
                    .PhoneMethods[MobilePhoneMethodId]
                    .GetAsync(cancellationToken: ct);

                _telemetry.IncrementCounter("GraphClient.MfaPhoneFetched");
                return method?.PhoneNumber;
            }
            catch (Microsoft.Graph.Models.ODataErrors.ODataError odataError)
                when (odataError.ResponseStatusCode == (int)System.Net.HttpStatusCode.NotFound)
            {
                // 404 = no mobile phone method registered for this user — normal, not an error
                _telemetry.IncrementCounter("GraphClient.MfaPhoneNotFound");
                return null;
            }
        }, cancellationToken);
    }

    public async Task RegisterPhoneAuthMethodAsync(
        string userIdOrUpn,
        string phoneNumber,
        CancellationToken cancellationToken = default)
    {
        await _retryPipeline.ExecuteAsync(async ct =>
        {
            try
            {
                var phoneMethod = new GraphModels.PhoneAuthenticationMethod
                {
                    PhoneNumber = phoneNumber,
                    PhoneType = GraphModels.AuthenticationPhoneType.Mobile
                };

                await _client.Users[userIdOrUpn].Authentication.PhoneMethods
                    .PostAsync(phoneMethod, cancellationToken: ct);

                _telemetry.IncrementCounter("GraphClient.PhoneMethodRegistered");
            }
            catch (Microsoft.Graph.Models.ODataErrors.ODataError odataError)
                when (odataError.ResponseStatusCode == (int)System.Net.HttpStatusCode.Conflict ||
                      (odataError.ResponseStatusCode == (int)System.Net.HttpStatusCode.BadRequest &&
                       odataError.Error?.Message != null &&
                       odataError.Error.Message.Contains("already registered", StringComparison.OrdinalIgnoreCase)))
            {
                // 409 = phone already registered (standard conflict)
                // 400 "already registered" = EEID returns BadRequest instead of Conflict in some cases
                // Both are treated as success (idempotent)
                _logger.LogDebug(
                    "Phone method already registered for user {User} ({Status} — skipping)",
                    userIdOrUpn, odataError.ResponseStatusCode);
                _telemetry.IncrementCounter("GraphClient.PhoneMethodAlreadyRegistered");
            }
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
}
