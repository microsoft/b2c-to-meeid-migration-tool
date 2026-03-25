// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
using B2CMigrationKit.Core.Abstractions;
using B2CMigrationKit.Core.Configuration;
using B2CMigrationKit.Core.Models;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using System.Text.Json;

namespace B2CMigrationKit.Core.Services.Orchestrators;

/// <summary>
/// Worker / Consumer phase of the unified migration pipeline.
///
/// Each instance independently:
///   1. Dequeues one message from the harvest queue (a JSON array of up to 20 B2C user IDs
///      enqueued by <see cref="HarvestOrchestrator"/>).
///   2. Calls <c>GET /users?$filter=id in (…)</c> via the Graph $batch API to fetch
///      full user profiles from Azure AD B2C.
///   3. Applies all attribute mappings and UPN / identity transformations.
///   4. Calls <c>POST /users</c> for each user in Entra External ID.
///   5. Enqueues a <see cref="PhoneRegistrationMessage"/> ({B2CUserId, EEIDUpn}) on the
///      phone-registration queue for Created and Duplicate users.
///   6. Writes a <see cref="MigrationAuditRecord"/> row to Azure Table Storage recording
///      the exact outcome (Created / Duplicate / Failed) with error details when applicable.
///   7. Deletes the harvest queue message.
///   8. Repeats until the queue is empty.
///
/// Multiple instances can run simultaneously, each using a different EEID App Registration,
/// multiplying the effective API throughput. Azure Queue visibility timeout provides
/// automatic retry: if a worker crashes before deleting the message, it reappears.
/// </summary>
public class WorkerMigrateOrchestrator : IOrchestrator<ExecutionResult>
{
    private readonly IGraphClient _b2cGraphClient;
    private readonly IGraphClient _eeidGraphClient;
    private readonly IQueueClient _queueClient;
    private readonly ITableStorageClient _tableClient;
    private readonly ITelemetryService _telemetry;
    private readonly ILogger<WorkerMigrateOrchestrator> _logger;
    private readonly MigrationOptions _options;

    public WorkerMigrateOrchestrator(
        IGraphClient b2cGraphClient,
        IGraphClient eeidGraphClient,
        IQueueClient queueClient,
        ITableStorageClient tableClient,
        ITelemetryService telemetry,
        IOptions<MigrationOptions> options,
        ILogger<WorkerMigrateOrchestrator> logger)
    {
        _b2cGraphClient = b2cGraphClient ?? throw new ArgumentNullException(nameof(b2cGraphClient));
        _eeidGraphClient = eeidGraphClient ?? throw new ArgumentNullException(nameof(eeidGraphClient));
        _queueClient = queueClient ?? throw new ArgumentNullException(nameof(queueClient));
        _tableClient = tableClient ?? throw new ArgumentNullException(nameof(tableClient));
        _telemetry = telemetry ?? throw new ArgumentNullException(nameof(telemetry));
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
        _options = options?.Value ?? throw new ArgumentNullException(nameof(options));
    }

    public async Task<ExecutionResult> ExecuteAsync(CancellationToken cancellationToken = default)
    {
        var summary = new RunSummary
        {
            OperationName = "Worker Migrate (B2C fetch → EEID create)",
            StartTime = DateTimeOffset.UtcNow
        };

        var harvestQueue    = _options.Harvest.QueueName;
        var phoneQueue      = _options.PhoneRegistration.QueueName;
        var visibilityTimeout = _options.Harvest.MessageVisibilityTimeout;
        var selectFields    = _options.Export.SelectFields;
        var auditTable      = _options.Storage.AuditTableName;

        int messagesProcessed = 0;
        int usersCreated  = 0;
        int usersDuplicate = 0;
        int usersFailed   = 0;
        int phonesEnqueued = 0;

        try
        {
            _logger.LogInformation("=== WORKER MIGRATE START ===");
            _logger.LogInformation("Harvest queue   : {Queue}", harvestQueue);
            _logger.LogInformation("Phone queue     : {Queue}", phoneQueue);
            _logger.LogInformation("Audit table     : {Table}", auditTable);
            _logger.LogInformation("Select fields   : {Fields}", selectFields);
            _logger.LogInformation("Visibility TTL  : {Timeout}", visibilityTimeout);
            _logger.LogInformation("Max concurrency : {Concurrency}", _options.MaxConcurrency);
            _logger.LogInformation("Skip phone queue : {Skip}", _options.Import.SkipPhoneRegistration);
            _telemetry.TrackEvent("WorkerMigrate.Started");

            // Validate EEID extension-attribute config before entering the loop
            ValidateExtensionAttributes();

            // Ensure infrastructure exists
            await _tableClient.EnsureTableExistsAsync(auditTable, cancellationToken);
            await _queueClient.CreateQueueIfNotExistsAsync(phoneQueue, cancellationToken);

            var overallStart = DateTimeOffset.UtcNow;
            var consecutiveEmptyPolls = 0;
            int maxEmptyPolls = 3;

            while (!cancellationToken.IsCancellationRequested)
            {
                var message = await _queueClient.ReceiveMessageAsync(
                    harvestQueue,
                    visibilityTimeout,
                    cancellationToken);

                if (message is null)
                {
                    consecutiveEmptyPolls++;
                    _logger.LogInformation(
                        "Queue empty (poll {Attempt}/{Max}). Waiting 5 seconds…",
                        consecutiveEmptyPolls, maxEmptyPolls);

                    if (consecutiveEmptyPolls >= maxEmptyPolls)
                    {
                        _logger.LogInformation(
                            "Queue confirmed empty after {Max} consecutive polls. Worker done.",
                            maxEmptyPolls);
                        break;
                    }

                    await Task.Delay(TimeSpan.FromSeconds(5), cancellationToken);
                    continue;
                }

                consecutiveEmptyPolls = 0;

                var (messageId, popReceipt, messageText) = message.Value;

                try
                {
                    var userIds = JsonSerializer.Deserialize<List<string>>(messageText);
                    if (userIds is null || userIds.Count == 0)
                    {
                        _logger.LogWarning("Received empty/invalid message {Id}, deleting.", messageId);
                        await SafeDeleteAsync(harvestQueue, messageId, popReceipt, cancellationToken);
                        continue;
                    }

                    // --------------------------------------------------------
                    // 1. Fetch full profiles from B2C via $batch
                    // --------------------------------------------------------
                    var fetchStart = DateTimeOffset.UtcNow;
                    var profiles = await _b2cGraphClient.GetUsersByIdsAsync(
                        userIds, selectFields, cancellationToken);
                    var fetchMs = (long)(DateTimeOffset.UtcNow - fetchStart).TotalMilliseconds;

                    _logger.LogInformation(
                        "[B2C-FETCH] msg={Id} fetched={Count}/{Total} in {FetchMs}ms",
                        messageId, profiles.Count, userIds.Count, fetchMs);
                    _telemetry.TrackEvent("WorkerMigrate.B2CFetch", new Dictionary<string, string>
                    {
                        ["messageId"]        = messageId,
                        ["fetched"]          = profiles.Count.ToString(),
                        ["requested"]        = userIds.Count.ToString(),
                        ["fetchMs"]          = fetchMs.ToString(),
                        ["avgB2cPerUserMs"]  = (profiles.Count > 0 ? fetchMs / profiles.Count : 0).ToString()
                    });

                    // --------------------------------------------------------
                    // 2. Transform + create each user in EEID (concurrent)
                    // --------------------------------------------------------
                    int batchCreated = 0, batchDuplicate = 0, batchFailed = 0, batchPhones = 0;
                    long batchEeidDurationSum = 0;
                    long batchEeidDurationMax = 0;
                    using var semaphore = new SemaphoreSlim(_options.MaxConcurrency);

                    var userTasks = profiles.Select(async user =>
                    {
                        await semaphore.WaitAsync(cancellationToken);
                        try
                        {
                            if (cancellationToken.IsCancellationRequested) return;

                            var b2cObjectId = user.Id ?? "unknown";
                            string? eeidUpn = null;
                            var opStart = DateTimeOffset.UtcNow;

                            try
                            {
                                // Apply all attribute transformations
                                PrepareUserForEeid(user);
                                eeidUpn = user.UserPrincipalName;

                                var eeidApiStart = DateTimeOffset.UtcNow;
                                var created = await _eeidGraphClient.CreateUserAsync(user, cancellationToken);
                                var eeidApiMs = (long)(DateTimeOffset.UtcNow - eeidApiStart).TotalMilliseconds;
                                var durationMs = (long)(DateTimeOffset.UtcNow - opStart).TotalMilliseconds;

                                Interlocked.Increment(ref batchCreated);
                                Interlocked.Add(ref batchEeidDurationSum, durationMs);
                                // Track max without lock
                                long prev = Interlocked.Read(ref batchEeidDurationMax);
                                while (durationMs > prev)
                                {
                                    long updated = Interlocked.CompareExchange(ref batchEeidDurationMax, durationMs, prev);
                                    if (updated == prev) break;
                                    prev = updated;
                                }

                                _logger.LogDebug(
                                    "Created user {UPN} (B2C: {B2CId}) → EEID: {EEIDId} in {Ms}ms",
                                    eeidUpn, b2cObjectId, created.Id, durationMs);

                                // Audit: Created
                                await _tableClient.UpsertAuditRecordAsync(
                                    MigrationAuditRecord.CreateMigrate(
                                        b2cObjectId, created.Id, eeidUpn, "Created", durationMs),
                                    auditTable, cancellationToken);

                                // Enqueue for phone registration (unless disabled)
                                if (!_options.Import.SkipPhoneRegistration)
                                {
                                    await EnqueuePhoneMessageAsync(b2cObjectId, eeidUpn, phoneQueue, cancellationToken);
                                    Interlocked.Increment(ref batchPhones);
                                }

                                _telemetry.TrackEvent("WorkerMigrate.UserCreated", new Dictionary<string, string>
                                {
                                    ["b2cObjectId"]  = b2cObjectId,
                                    ["eeidUpn"]      = eeidUpn ?? "unknown",
                                    ["eeidUserId"]   = created.Id ?? "unknown",
                                    ["eeidApiMs"]    = eeidApiMs.ToString(),
                                    ["eeidCreateMs"] = durationMs.ToString()
                                });
                            }
                            catch (Microsoft.Graph.Models.ODataErrors.ODataError odataErr)
                                when (odataErr.ResponseStatusCode == 409
                                    || (odataErr.ResponseStatusCode == 400
                                        && odataErr.Message != null
                                        && odataErr.Message.Contains("conflicting object", StringComparison.OrdinalIgnoreCase)))
                            {
                                var durationMs = (long)(DateTimeOffset.UtcNow - opStart).TotalMilliseconds;
                                Interlocked.Increment(ref batchDuplicate);
                                Interlocked.Add(ref batchEeidDurationSum, durationMs);

                                _logger.LogInformation(
                                    "User {UPN} (B2C: {B2CId}) already exists in EEID — Duplicate",
                                    eeidUpn ?? b2cObjectId, b2cObjectId);

                                // Audit: Duplicate
                                await _tableClient.UpsertAuditRecordAsync(
                                    MigrationAuditRecord.CreateMigrate(
                                        b2cObjectId, null, eeidUpn, "Duplicate", durationMs,
                                        "409", "User already exists (ObjectConflict)"),
                                    auditTable, cancellationToken);

                                // Still enqueue for phone — user exists and may not have phone registered
                                if (!string.IsNullOrWhiteSpace(eeidUpn) && !_options.Import.SkipPhoneRegistration)
                                {
                                    await EnqueuePhoneMessageAsync(b2cObjectId, eeidUpn, phoneQueue, cancellationToken);
                                    Interlocked.Increment(ref batchPhones);
                                }

                                _telemetry.TrackEvent("WorkerMigrate.UserDuplicate", new Dictionary<string, string>
                                {
                                    ["b2cObjectId"]  = b2cObjectId,
                                    ["eeidUpn"]      = eeidUpn ?? "unknown",
                                    ["eeidCreateMs"] = durationMs.ToString()
                                });
                            }
                            catch (Exception ex)
                            {
                                var durationMs = (long)(DateTimeOffset.UtcNow - opStart).TotalMilliseconds;
                                Interlocked.Increment(ref batchFailed);
                                Interlocked.Add(ref batchEeidDurationSum, durationMs);

                                var errorCode = ex is Microsoft.Graph.Models.ODataErrors.ODataError oErr
                                    ? oErr.ResponseStatusCode.ToString()
                                    : ex.GetType().Name;

                                _logger.LogWarning(ex,
                                    "Failed to create user {UPN} (B2C: {B2CId}) — {Error}",
                                    eeidUpn ?? b2cObjectId, b2cObjectId, ex.Message);

                                // Audit: Failed
                                await _tableClient.UpsertAuditRecordAsync(
                                    MigrationAuditRecord.CreateMigrate(
                                        b2cObjectId, null, eeidUpn, "Failed", durationMs,
                                        errorCode, ex.Message),
                                    auditTable, cancellationToken);

                                _telemetry.TrackEvent("WorkerMigrate.UserFailed", new Dictionary<string, string>
                                {
                                    ["b2cObjectId"]  = b2cObjectId,
                                    ["eeidUpn"]      = eeidUpn ?? "unknown",
                                    ["eeidCreateMs"] = durationMs.ToString(),
                                    ["errorCode"]    = errorCode,
                                    ["error"]        = ex.Message
                                });
                            }
                        }
                        finally
                        {
                            semaphore.Release();
                        }
                    });

                    await Task.WhenAll(userTasks);

                    // Log per-batch timing summary
                    var batchTotal = batchCreated + batchDuplicate + batchFailed;
                    var avgEeidMs  = batchTotal > 0 ? batchEeidDurationSum / batchTotal : 0;
                    _logger.LogInformation(
                        "[BATCH] msg={Id} users={Total} created={C} dup={D} failed={F} | eeid avg={AvgMs}ms max={MaxMs}ms | b2c={FetchMs}ms",
                        messageId, profiles.Count, batchCreated, batchDuplicate, batchFailed,
                        avgEeidMs, batchEeidDurationMax, fetchMs);
                    _telemetry.TrackEvent("WorkerMigrate.BatchDone", new Dictionary<string, string>
                    {
                        ["messageId"]   = messageId,
                        ["users"]       = profiles.Count.ToString(),
                        ["created"]     = batchCreated.ToString(),
                        ["duplicate"]   = batchDuplicate.ToString(),
                        ["failed"]      = batchFailed.ToString(),
                        ["eeidAvgMs"]   = avgEeidMs.ToString(),
                        ["eeidMaxMs"]   = batchEeidDurationMax.ToString(),
                        ["b2cFetchMs"]  = fetchMs.ToString()
                    });

                    // Aggregate batch results into outer counters (single-threaded after WhenAll)
                    usersCreated   += batchCreated;
                    usersDuplicate += batchDuplicate;
                    usersFailed    += batchFailed;
                    phonesEnqueued += batchPhones;
                    summary.SuccessCount += batchCreated;
                    summary.SkippedCount += batchDuplicate;
                    summary.FailureCount += batchFailed;
                    summary.TotalItems   += profiles.Count;

                    messagesProcessed++;

                    // --------------------------------------------------------
                    // 3. ACK — delete the harvest queue message
                    // --------------------------------------------------------
                    await SafeDeleteAsync(harvestQueue, messageId, popReceipt, cancellationToken);

                    // Progress checkpoint every 50 messages
                    if (messagesProcessed % 50 == 0)
                    {
                        var elapsed = (DateTimeOffset.UtcNow - overallStart).TotalSeconds;
                        var rate = elapsed > 0 ? summary.TotalItems / elapsed : 0;
                        var remaining = await _queueClient.GetQueueLengthAsync(harvestQueue, cancellationToken);

                        _logger.LogInformation(
                            "╔══════════════════════════════════════════════════╗\n" +
                            "  PROGRESS CHECKPOINT (every 50 messages)\n" +
                            "  Messages done   : {Messages:N0}\n" +
                            "  Users created   : {Created:N0}\n" +
                            "  Duplicates      : {Dup:N0}\n" +
                            "  Failed          : {Failed:N0}\n" +
                            "  Phones enqueued : {Phones:N0}\n" +
                            "  Queue remaining : {Remaining:N0} msgs\n" +
                            "  Elapsed         : {Elapsed}\n" +
                            "  Rate            : {Rate:F1} users/s\n" +
                            "╚══════════════════════════════════════════════════╝",
                            messagesProcessed, usersCreated, usersDuplicate, usersFailed, phonesEnqueued,
                            remaining < 0 ? "?" : remaining,
                            TimeSpan.FromSeconds(elapsed).ToString(@"hh\:mm\:ss"),
                            rate);
                    }
                }
                catch (Exception ex)
                {
                    // Do NOT delete the message — let it reappear after visibility timeout
                    summary.FailureCount++;
                    _logger.LogError(ex,
                        "Failed to process message {Id}. Will reappear after visibility timeout.",
                        messageId);
                    _telemetry.TrackException(ex);
                }

                if (_options.BatchDelayMs > 0)
                    await Task.Delay(_options.BatchDelayMs, cancellationToken);
            }

            summary.EndTime = DateTimeOffset.UtcNow;
            var totalElapsed = summary.Duration.TotalSeconds;
            var finalRate = totalElapsed > 0 ? summary.TotalItems / totalElapsed : 0;

            _logger.LogInformation(
                "=== WORKER MIGRATE SUMMARY ===\n" +
                "Messages processed : {Messages:N0}\n" +
                "Users created      : {Created:N0}\n" +
                "Duplicates         : {Dup:N0}\n" +
                "Failed             : {Failed:N0}\n" +
                "Phones enqueued    : {Phones:N0}\n" +
                "Duration           : {Duration}\n" +
                "Throughput         : {Rate:F2} users/second",
                messagesProcessed, usersCreated, usersDuplicate, usersFailed,
                phonesEnqueued, summary.Duration, finalRate);

            _telemetry.TrackEvent("WorkerMigrate.Completed", new Dictionary<string, string>
            {
                { "Created",   usersCreated.ToString() },
                { "Duplicate", usersDuplicate.ToString() },
                { "Failed",    usersFailed.ToString() },
                { "Duration",  summary.Duration.ToString() },
                { "Rate",      finalRate.ToString("F2") }
            });

            await _telemetry.FlushAsync();

            return new ExecutionResult
            {
                Success = usersFailed == 0,
                StartTime = summary.StartTime,
                EndTime = summary.EndTime,
                Summary = summary,
                ErrorMessage = usersFailed > 0
                    ? $"{usersFailed} user(s) failed. Check the '{auditTable}' table for details."
                    : null
            };
        }
        catch (Exception ex)
        {
            summary.EndTime = DateTimeOffset.UtcNow;
            _logger.LogError(ex, "Worker migrate fatal error");
            _telemetry.TrackException(ex);

            return new ExecutionResult
            {
                Success = false,
                ErrorMessage = ex.Message,
                Exception = ex,
                StartTime = summary.StartTime,
                EndTime = summary.EndTime,
                Summary = summary
            };
        }
    }

    // -------------------------------------------------------------------------
    // Private helpers
    // -------------------------------------------------------------------------

    private async Task EnqueuePhoneMessageAsync(
        string b2cUserId,
        string? eeidUpn,
        string phoneQueue,
        CancellationToken cancellationToken)
    {
        if (string.IsNullOrWhiteSpace(eeidUpn)) return;
        var msg = new PhoneRegistrationMessage
        {
            B2CUserId = b2cUserId,
            EEIDUpn = eeidUpn
        };
        var json = JsonSerializer.Serialize(msg);
        await _queueClient.SendMessageAsync(phoneQueue, json, cancellationToken);
    }

    /// <summary>
    /// Applies all user transformations in-place before calling CreateUserAsync.
    /// </summary>
    private void PrepareUserForEeid(UserProfile user)
    {
        // 1. Attribute mappings / exclusions
        ApplyAttributeMappings(user);

        // 2. Store original B2C ObjectId as extension attribute
        if (_options.Import.MigrationAttributes.StoreB2CObjectId)
        {
            var attrName = GetB2CObjectIdAttributeName();
            user.ExtensionAttributes[attrName] = user.Id!;
        }

        // 3. Set RequiresMigration = true (user needs JIT migration on first login)
        if (_options.Import.MigrationAttributes.SetRequireMigration)
        {
            user.ExtensionAttributes[GetRequireMigrationAttributeName()] = true;
        }

        // 4. Transform UPN domain: b2ctenant.onmicrosoft.com → eeidtenant.onmicrosoft.com
        if (!string.IsNullOrEmpty(user.UserPrincipalName))
            user.UserPrincipalName = TransformUpn(user.UserPrincipalName);

        // 5. Ensure emailAddress identity exists (required for OTP / password reset)
        EnsureEmailIdentity(user);

        // 6. Update issuer on all identities to the EEID tenant domain
        if (user.Identities != null)
        {
            foreach (var identity in user.Identities)
            {
                identity.Issuer = _options.ExternalId.TenantDomain;

                if (identity.SignInType?.ToLower() == "userprincipalname" &&
                    !string.IsNullOrEmpty(identity.IssuerAssignedId))
                {
                    identity.IssuerAssignedId = TransformUpn(identity.IssuerAssignedId);
                }
                else if (!string.IsNullOrEmpty(_options.Import.UpnSuffix) &&
                         identity.SignInType?.ToLower() == "emailaddress" &&
                         !string.IsNullOrEmpty(identity.IssuerAssignedId))
                {
                    var emailAt = identity.IssuerAssignedId.IndexOf('@');
                    if (emailAt > 0)
                        identity.IssuerAssignedId = identity.IssuerAssignedId[..emailAt] + _options.Import.UpnSuffix + identity.IssuerAssignedId[emailAt..];
                }
            }
        }

        // 7. Set a random initial password (never shown to users — JIT migration handles auth)
        user.PasswordProfile = new PasswordProfile
        {
            Password = GenerateRandomPassword(),
            ForceChangePasswordNextSignIn = false
        };
    }

    private void ValidateExtensionAttributes()
    {
        if (string.IsNullOrWhiteSpace(_options.ExternalId.ExtensionAppId))
            throw new InvalidOperationException(
                "ExtensionAppId not configured. Set Migration.ExternalId.ExtensionAppId.");

        if (_options.ExternalId.ExtensionAppId.Contains('-'))
            throw new InvalidOperationException(
                $"ExtensionAppId must not contain dashes. Value: {_options.ExternalId.ExtensionAppId}");

        _logger.LogInformation(
            "Config: AttrMappings={AttrCount} ExcludeFields={ExcludeCount} " +
            "StoreB2CObjectId={StoreId} SetRequireMigration={SetMig} UpnSuffix={UpnSuffix}",
            _options.Import.AttributeMappings.Count,
            _options.Import.ExcludeFields.Count,
            _options.Import.MigrationAttributes.StoreB2CObjectId,
            _options.Import.MigrationAttributes.SetRequireMigration,
            _options.Import.UpnSuffix ?? "(none)");
    }

    private void ApplyAttributeMappings(UserProfile user)
    {
        if (_options.Import.AttributeMappings.Count > 0)
        {
            var mapped = new Dictionary<string, object>();
            foreach (var kvp in user.ExtensionAttributes)
            {
                if (_options.Import.AttributeMappings.TryGetValue(kvp.Key, out var target))
                    mapped[target] = kvp.Value;
                else if (!_options.Import.ExcludeFields.Contains(kvp.Key))
                    mapped[kvp.Key] = kvp.Value;
            }
            user.ExtensionAttributes = mapped;
        }
        else if (_options.Import.ExcludeFields.Count > 0)
        {
            foreach (var field in _options.Import.ExcludeFields)
                user.ExtensionAttributes.Remove(field);
        }
    }

    private string GetB2CObjectIdAttributeName()
    {
        return !string.IsNullOrEmpty(_options.Import.MigrationAttributes.B2CObjectIdTarget)
            ? _options.Import.MigrationAttributes.B2CObjectIdTarget
            : MigrationExtensionAttributes.GetFullAttributeName(
                _options.ExternalId.ExtensionAppId,
                MigrationExtensionAttributes.B2CObjectId);
    }

    private string GetRequireMigrationAttributeName()
    {
        return !string.IsNullOrEmpty(_options.Import.MigrationAttributes.RequireMigrationTarget)
            ? _options.Import.MigrationAttributes.RequireMigrationTarget
            : MigrationExtensionAttributes.GetFullAttributeName(
                _options.ExternalId.ExtensionAppId,
                MigrationExtensionAttributes.RequiresMigration);
    }

    private string TransformUpn(string b2cUpn)
    {
        if (string.IsNullOrEmpty(b2cUpn)) return b2cUpn;
        var at = b2cUpn.IndexOf('@');
        if (at == -1) return b2cUpn;
        var local = b2cUpn[..at];
        if (string.IsNullOrEmpty(local))
            local = Guid.NewGuid().ToString("N")[..8];
        if (!string.IsNullOrEmpty(_options.Import.UpnSuffix))
            local += _options.Import.UpnSuffix;
        return $"{local}@{_options.ExternalId.TenantDomain}";
    }

    private void EnsureEmailIdentity(UserProfile user)
    {
        var hasEmail = user.Identities?.Any(i =>
            string.Equals(i.SignInType, "emailAddress", StringComparison.OrdinalIgnoreCase)) ?? false;

        if (hasEmail) return;

        var email = string.IsNullOrEmpty(user.Mail) ? user.UserPrincipalName : user.Mail;

        // Apply UpnSuffix to email identity to avoid collisions with previous migrations
        if (!string.IsNullOrEmpty(_options.Import.UpnSuffix) && !string.IsNullOrEmpty(email))
        {
            var emailAt = email.IndexOf('@');
            if (emailAt > 0)
                email = email[..emailAt] + _options.Import.UpnSuffix + email[emailAt..];
        }

        user.Identities ??= new List<ObjectIdentity>();
        user.Identities.Add(new ObjectIdentity
        {
            SignInType = "emailAddress",
            Issuer = _options.ExternalId.TenantDomain,
            IssuerAssignedId = email
        });
    }

    private async Task SafeDeleteAsync(
        string queueName,
        string messageId,
        string popReceipt,
        CancellationToken cancellationToken)
    {
        try
        {
            await _queueClient.DeleteMessageAsync(queueName, messageId, popReceipt, cancellationToken);
        }
        catch (Exception ex)
        {
            // Pop-receipt may have expired if processing exceeded the visibility timeout.
            // The message will reappear and be re-processed (all operations are idempotent).
            _logger.LogWarning(ex,
                "[WorkerMigrate] Failed to delete message {Id} from queue {Queue} — it may be reprocessed (idempotent).",
                messageId, queueName);
        }
    }

    private static string GenerateRandomPassword()
    {
        const string upper   = "ABCDEFGHJKLMNPQRSTUVWXYZ";
        const string lower   = "abcdefghijkmnpqrstuvwxyz";
        const string digits  = "23456789";
        const string special = "!@#$%^&*";
        const string all     = upper + lower + digits + special;

        var rng = new Random();
        var chars = new List<char>
        {
            upper[rng.Next(upper.Length)],
            lower[rng.Next(lower.Length)],
            digits[rng.Next(digits.Length)],
            special[rng.Next(special.Length)]
        };
        for (int i = 4; i < 16; i++) chars.Add(all[rng.Next(all.Length)]);
        for (int i = chars.Count - 1; i > 0; i--)
        {
            int j = rng.Next(i + 1);
            (chars[i], chars[j]) = (chars[j], chars[i]);
        }
        return new string(chars.ToArray());
    }
}
