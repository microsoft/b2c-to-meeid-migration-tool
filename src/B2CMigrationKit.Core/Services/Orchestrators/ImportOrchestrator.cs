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
/// Orchestrates the bulk import of users from Blob Storage to Entra External ID.
/// </summary>
public class ImportOrchestrator : IOrchestrator<ExecutionResult>
{
    private readonly IGraphClient _externalIdGraphClient;
    private readonly IBlobStorageClient _blobClient;
    private readonly ITelemetryService _telemetry;
    private readonly ILogger<ImportOrchestrator> _logger;
    private readonly MigrationOptions _options;

    public ImportOrchestrator(
        IGraphClient externalIdGraphClient,
        IBlobStorageClient blobClient,
        ITelemetryService telemetry,
        IOptions<MigrationOptions> options,
        ILogger<ImportOrchestrator> logger)
    {
        _externalIdGraphClient = externalIdGraphClient ?? throw new ArgumentNullException(nameof(externalIdGraphClient));
        _blobClient = blobClient ?? throw new ArgumentNullException(nameof(blobClient));
        _telemetry = telemetry ?? throw new ArgumentNullException(nameof(telemetry));
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
        _options = options?.Value ?? throw new ArgumentNullException(nameof(options));
    }

    public async Task<ExecutionResult> ExecuteAsync(CancellationToken cancellationToken = default)
    {
        var summary = new RunSummary
        {
            OperationName = "External ID User Import",
            StartTime = DateTimeOffset.UtcNow
        };

        // Track aggregated metrics for cost estimation
        long totalBlobBytesRead = 0;
        int totalGraphApiCalls = 0;

        try
        {
            _logger.LogInformation("Starting External ID user import");
            _telemetry.TrackEvent("Import.Started");

            // Validate extension attributes configuration
            ValidateExtensionAttributes();

            // Ensure import audit container exists
            await _blobClient.EnsureContainerExistsAsync(
                _options.Storage.ImportAuditContainerName,
                cancellationToken);

            _logger.LogInformation("Import audit logs will be saved to container: {Container}",
                _options.Storage.ImportAuditContainerName);

            // List all export blobs
            var blobs = await _blobClient.ListBlobsAsync(
                _options.Storage.ExportContainerName,
                _options.Storage.ExportBlobPrefix,
                cancellationToken);

            var blobList = blobs.OrderBy(b => b).ToList();
            _logger.LogInformation("Found {Count} export files to process", blobList.Count);

            foreach (var blobName in blobList)
            {
                if (cancellationToken.IsCancellationRequested) break;

                try
                {
                    // Read users from blob
                    var json = await _blobClient.ReadBlobAsync(
                        _options.Storage.ExportContainerName,
                        blobName,
                        cancellationToken);

                    // Track blob bytes for cost estimation
                    totalBlobBytesRead += System.Text.Encoding.UTF8.GetByteCount(json);

                    var users = JsonSerializer.Deserialize<List<UserProfile>>(json);

                    if (users == null || !users.Any())
                    {
                        _logger.LogWarning("Blob {Blob} contains no users", blobName);
                        continue;
                    }

                    _logger.LogInformation("Processing {Count} users from {Blob}", users.Count, blobName);

                    var batchNumber = 0;

                    // Process users in batches
                    foreach (var batch in users.Chunk(_options.BatchSize))
                    {
                        var batchStartTime = DateTimeOffset.UtcNow;
                        var originalUserIds = new Dictionary<int, string>();

                        // Store original IDs for audit log
                        for (int i = 0; i < batch.Length; i++)
                        {
                            originalUserIds[i] = batch[i].Id ?? "unknown";
                        }
                        // Prepare users for import
                        foreach (var user in batch)
                        {
                            // Apply attribute mappings and transformations
                            ApplyAttributeMappings(user);

                            // Store original B2C ObjectId (if configured)
                            if (_options.Import.MigrationAttributes.StoreB2CObjectId)
                            {
                                var b2cObjectIdAttr = GetB2CObjectIdAttributeName();
                                user.ExtensionAttributes[b2cObjectIdAttr] = user.Id!;

                                if (_options.VerboseLogging)
                                {
                                    _logger.LogDebug("Storing B2C ObjectId {ObjectId} as {AttrName}", user.Id, b2cObjectIdAttr);
                                }
                            }

                            // Set RequiresMigration flag (if configured)
                            if (_options.Import.MigrationAttributes.SetRequireMigration)
                            {
                                var requireMigrationAttr = GetRequireMigrationAttributeName();
                                user.ExtensionAttributes[requireMigrationAttr] = true; // Set to true - user REQUIRES JIT migration on first login

                                if (_options.VerboseLogging)
                                {
                                    _logger.LogDebug("Setting migration flag to true (requires migration) as {AttrName}", requireMigrationAttr);
                                }
                            }

                            // Transform UPN from B2C to External ID compatible format
                            if (!string.IsNullOrEmpty(user.UserPrincipalName))
                            {
                                user.UserPrincipalName = TransformUpnForExternalId(user.UserPrincipalName);
                            }

                            // Ensure user has an email identity (required for OTP and password reset in External ID)
                            EnsureEmailIdentity(user);

                            // Update identities issuer and issuerAssignedId
                            if (user.Identities != null && user.Identities.Any())
                            {
                                foreach (var identity in user.Identities)
                                {
                                    // ALWAYS update issuer to External ID domain (for cross-tenant migration)
                                    // This is required because External ID validates that issuer matches tenant domain
                                    identity.Issuer = _options.ExternalId.TenantDomain;

                                    // Preserve userPrincipalName identity (External ID supports it)
                                    // Only update the domain in the issuerAssignedId
                                    if (identity.SignInType?.ToLower() == "userprincipalname" &&
                                        !string.IsNullOrEmpty(identity.IssuerAssignedId))
                                    {
                                        // Keep signInType as "userPrincipalName" (don't convert to userName)
                                        // Update the issuerAssignedId domain to External ID tenant
                                        identity.IssuerAssignedId = TransformUpnForExternalId(identity.IssuerAssignedId);
                                    }
                                }

                                if (_options.VerboseLogging)
                                {
                                    _logger.LogDebug("User has {Count} identities: {Types}",
                                        user.Identities.Count,
                                        string.Join(", ", user.Identities.Select(i => i.SignInType)));
                                }
                            }

                            // Set random password with forceChangePasswordNextSignIn = false
                            // External ID requires false for JIT migration scenarios
                            user.PasswordProfile = new PasswordProfile
                            {
                                Password = GenerateRandomPassword(),
                                ForceChangePasswordNextSignIn = false
                            };
                        }

                        // Batch create users
                        var result = await _externalIdGraphClient.CreateUsersBatchAsync(
                            batch,
                            cancellationToken);

                        // Track Graph API call for cost estimation
                        totalGraphApiCalls++;

                        summary.TotalItems += result.TotalItems;
                        summary.SuccessCount += result.SuccessCount;
                        summary.FailureCount += result.FailureCount;
                        summary.SkippedCount += result.SkippedCount;

                        if (result.WasThrottled)
                        {
                            summary.ThrottleCount++;
                        }

                        _logger.LogInformation("Batch result: {Success} succeeded, {Skipped} skipped (already exist), {Failed} failed",
                            result.SuccessCount, result.SkippedCount, result.FailureCount);

                        // Update extension attributes for duplicate users if configured
                        if (_options.Import.MigrationAttributes.OverwriteExtensionAttributes && result.DuplicateUsers.Any())
                        {
                            _logger.LogInformation("OverwriteExtensionAttributes enabled - updating {Count} duplicate users",
                                result.DuplicateUsers.Count);

                            var updateCount = await UpdateExtensionAttributesForDuplicatesAsync(
                                result.DuplicateUsers,
                                cancellationToken);

                            _logger.LogInformation("Updated extension attributes for {Count} duplicate users", updateCount);
                        }

                        // Create and save audit log for this batch
                        var auditLog = CreateAuditLog(
                            blobName,
                            batchNumber,
                            batch,
                            originalUserIds,
                            result,
                            batchStartTime);

                        await SaveAuditLogAsync(auditLog, blobName, batchNumber, cancellationToken);

                        batchNumber++;

                        // Add delay between batches
                        if (_options.BatchDelayMs > 0)
                        {
                            await Task.Delay(_options.BatchDelayMs, cancellationToken);
                        }
                    }

                    _telemetry.IncrementCounter("Import.BlobsProcessed");
                }
                catch (Exception ex)
                {
                    _logger.LogError(ex, "Failed to process blob {Blob}", blobName);
                    summary.FailureCount++;
                }
            }

            summary.EndTime = DateTimeOffset.UtcNow;

            _logger.LogInformation(summary.ToString());

            // Track aggregated metrics for cost estimation
            _telemetry.TrackMetric("import.blob.read.bytes", totalBlobBytesRead);
            _telemetry.TrackMetric("import.graph.api.calls", totalGraphApiCalls);

            _telemetry.TrackEvent("Import.Completed", new Dictionary<string, string>
            {
                { "TotalUsers", summary.TotalItems.ToString() },
                { "SuccessCount", summary.SuccessCount.ToString() },
                { "SkippedCount", summary.SkippedCount.ToString() },
                { "FailureCount", summary.FailureCount.ToString() },
                { "Duration", summary.Duration.ToString() }
            });

            await _telemetry.FlushAsync();

            return new ExecutionResult
            {
                Success = summary.FailureCount == 0,
                StartTime = summary.StartTime,
                EndTime = summary.EndTime,
                Summary = summary
            };
        }
        catch (Exception ex)
        {
            summary.EndTime = DateTimeOffset.UtcNow;
            _logger.LogError(ex, "Import failed");
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

    private void ValidateExtensionAttributes()
    {
        _logger.LogInformation("Validating extension attributes configuration...");

        if (string.IsNullOrWhiteSpace(_options.ExternalId.ExtensionAppId))
        {
            throw new InvalidOperationException(
                "Extension App ID is not configured. Please set Migration.ExternalId.ExtensionAppId in your configuration.");
        }

        // Check if Extension App ID contains dashes (common mistake)
        if (_options.ExternalId.ExtensionAppId.Contains("-"))
        {
            throw new InvalidOperationException(
                $"Extension App ID must not contain dashes. Current value: {_options.ExternalId.ExtensionAppId}. " +
                "Please remove all dashes from the GUID.");
        }

        _logger.LogInformation("Import configuration:");
        _logger.LogInformation("  - Attribute mappings: {Count}", _options.Import.AttributeMappings.Count);
        _logger.LogInformation("  - Exclude fields: {Count}", _options.Import.ExcludeFields.Count);
        _logger.LogInformation("  - Store B2C ObjectId: {StoreB2C}", _options.Import.MigrationAttributes.StoreB2CObjectId);
        _logger.LogInformation("  - Set RequireMigration: {SetMigrated}", _options.Import.MigrationAttributes.SetRequireMigration);

        if (_options.Import.MigrationAttributes.StoreB2CObjectId)
        {
            var b2cAttr = GetB2CObjectIdAttributeName();
            _logger.LogInformation("  - B2CObjectId target: {Attr}", b2cAttr);
        }

        if (_options.Import.MigrationAttributes.SetRequireMigration)
        {
            var requireMigrationAttr = GetRequireMigrationAttributeName();
            _logger.LogInformation("  - Migration flag target: {Attr} (will be set to true)", requireMigrationAttr);
        }

        if (_options.Import.AttributeMappings.Any())
        {
            _logger.LogInformation("Attribute mappings:");
            foreach (var mapping in _options.Import.AttributeMappings)
            {
                _logger.LogInformation("  - {Source} → {Target}", mapping.Key, mapping.Value);
            }
        }

        _logger.LogWarning(
            "⚠️  IMPORTANT: Ensure all target custom attributes exist in External ID tenant at " +
            "External Identities > Custom user attributes. " +
            "If they don't exist, the import will fail. " +
            "See User Guide for instructions on creating them.");
    }

    private void ApplyAttributeMappings(UserProfile user)
    {
        // Apply attribute name mappings
        if (_options.Import.AttributeMappings.Any())
        {
            var mappedAttributes = new Dictionary<string, object>();

            foreach (var kvp in user.ExtensionAttributes)
            {
                var sourceAttr = kvp.Key;
                var value = kvp.Value;

                // Check if this attribute should be mapped to a different name
                if (_options.Import.AttributeMappings.ContainsKey(sourceAttr))
                {
                    var targetAttr = _options.Import.AttributeMappings[sourceAttr];
                    mappedAttributes[targetAttr] = value;

                    if (_options.VerboseLogging)
                    {
                        _logger.LogDebug("Mapping attribute {Source} → {Target}", sourceAttr, targetAttr);
                    }
                }
                else if (!_options.Import.ExcludeFields.Contains(sourceAttr))
                {
                    // Keep as-is if not excluded
                    mappedAttributes[sourceAttr] = value;
                }
                else if (_options.VerboseLogging)
                {
                    _logger.LogDebug("Excluding attribute {Attr}", sourceAttr);
                }
            }

            user.ExtensionAttributes = mappedAttributes;
        }
        else if (_options.Import.ExcludeFields.Any())
        {
            // Just apply exclusions if no mappings
            foreach (var excludeField in _options.Import.ExcludeFields)
            {
                if (user.ExtensionAttributes.Remove(excludeField) && _options.VerboseLogging)
                {
                    _logger.LogDebug("Excluding attribute {Attr}", excludeField);
                }
            }
        }
    }

    private string GetB2CObjectIdAttributeName()
    {
        if (!string.IsNullOrEmpty(_options.Import.MigrationAttributes.B2CObjectIdTarget))
        {
            return _options.Import.MigrationAttributes.B2CObjectIdTarget;
        }

        // Default: extension_{appId}_B2CObjectId
        return MigrationExtensionAttributes.GetFullAttributeName(
            _options.ExternalId.ExtensionAppId,
            MigrationExtensionAttributes.B2CObjectId);
    }

    private string GetRequireMigrationAttributeName()
    {
        if (!string.IsNullOrEmpty(_options.Import.MigrationAttributes.RequireMigrationTarget))
        {
            return _options.Import.MigrationAttributes.RequireMigrationTarget;
        }

        // Default: extension_{appId}_RequireMigration
        return MigrationExtensionAttributes.GetFullAttributeName(
            _options.ExternalId.ExtensionAppId,
            MigrationExtensionAttributes.RequireMigration);
    }

    private ImportAuditLog CreateAuditLog(
        string sourceBlobName,
        int batchNumber,
        UserProfile[] batch,
        Dictionary<int, string> originalUserIds,
        BatchResult result,
        DateTimeOffset batchStartTime)
    {
        var auditLog = new ImportAuditLog
        {
            Timestamp = DateTimeOffset.UtcNow,
            SourceBlobName = sourceBlobName,
            BatchNumber = batchNumber,
            TotalUsers = batch.Length,
            SuccessCount = result.SuccessCount,
            FailureCount = result.FailureCount,
            SkippedCount = result.SkippedCount,
            DurationMs = (DateTimeOffset.UtcNow - batchStartTime).TotalMilliseconds
        };

        // Categorize users based on batch result
        for (int i = 0; i < batch.Length; i++)
        {
            var user = batch[i];
            var originalId = originalUserIds.ContainsKey(i) ? originalUserIds[i] : "unknown";
            var upn = user.UserPrincipalName ?? "unknown";

            // Check if this user was skipped (duplicate)
            if (result.SkippedUserIds.Contains(upn))
            {
                auditLog.SkippedUsers.Add(new SkippedUserRecord
                {
                    B2CObjectId = originalId,
                    UserPrincipalName = upn,
                    DisplayName = user.DisplayName ?? "unknown",
                    Reason = "Duplicate - User already exists",
                    SkippedAt = DateTimeOffset.UtcNow
                });
            }
            // Otherwise assume success (failures would need more detailed tracking)
            else if (result.SuccessCount > 0)
            {
                auditLog.SuccessfulUsers.Add(new ImportedUserRecord
                {
                    B2CObjectId = originalId,
                    ExternalIdObjectId = user.Id ?? "created",
                    UserPrincipalName = upn,
                    DisplayName = user.DisplayName ?? "unknown",
                    ImportedAt = DateTimeOffset.UtcNow
                });
            }
        }

        // Note: Failed users are tracked via result.Failures
        // For detailed failure tracking, we would need to enhance the batch operation response handling

        return auditLog;
    }

    private async Task SaveAuditLogAsync(
        ImportAuditLog auditLog,
        string sourceBlobName,
        int batchNumber,
        CancellationToken cancellationToken)
    {
        try
        {
            // Generate audit log blob name: import-audit_{sourceBlobName}_batch{batchNumber}_{timestamp}.json
            var timestamp = DateTimeOffset.UtcNow.ToString("yyyyMMddHHmmss");
            var cleanBlobName = sourceBlobName.Replace(".json", "").Replace(_options.Storage.ExportBlobPrefix, "");
            var auditBlobName = $"import-audit_{cleanBlobName}_batch{batchNumber:D3}_{timestamp}.json";

            var json = JsonSerializer.Serialize(auditLog, new JsonSerializerOptions
            {
                WriteIndented = true
            });

            await _blobClient.WriteBlobAsync(
                _options.Storage.ImportAuditContainerName,
                auditBlobName,
                json,
                cancellationToken);

            if (_options.VerboseLogging)
            {
                _logger.LogDebug("Saved audit log: {AuditBlobName}", auditBlobName);
            }

            _telemetry.IncrementCounter("Import.AuditLogsSaved");
        }
        catch (Exception ex)
        {
            _logger.LogWarning(ex, "Failed to save audit log for batch {BatchNumber} from {SourceBlob}",
                batchNumber, sourceBlobName);
            // Don't fail the import if audit log save fails
        }
    }

    private string TransformUpnForExternalId(string b2cUpn)
    {
        // Transform B2C UPN to External ID compatible format by replacing domain only
        // Examples:
        //   testuser@b2c.onmicrosoft.com → testuser@externalid.onmicrosoft.com
        //   user@source.onmicrosoft.com → user@target.onmicrosoft.com
        //   05001e5c-946f-49d6-ba39-23d5292d1c3d@b2c.onmicrosoft.com → 05001e5c-946f-49d6-ba39-23d5292d1c3d@externalid.onmicrosoft.com

        if (string.IsNullOrEmpty(b2cUpn))
            return b2cUpn;

        var atIndex = b2cUpn.IndexOf('@');
        if (atIndex == -1)
            return b2cUpn; // Invalid format, return as-is

        // Preserve the local part (everything before @) exactly as-is
        var localPart = b2cUpn.Substring(0, atIndex);
        
        // Ensure local part is not empty
        if (string.IsNullOrEmpty(localPart))
        {
            localPart = Guid.NewGuid().ToString("N").Substring(0, 8); // Use first 8 chars of GUID
        }

        // Replace domain with External ID tenant domain
        var newUpn = $"{localPart}@{_options.ExternalId.TenantDomain}";

        if (_options.VerboseLogging)
        {
            _logger.LogDebug("Transformed UPN: {OldUpn} → {NewUpn}", b2cUpn, newUpn);
        }

        return newUpn;
    }

    private void EnsureEmailIdentity(UserProfile user)
    {
        // Determine which identity type to create based on configuration
        var targetSignInType = _options.Import.MigrationAttributes.UseEmailOtp 
            ? "federated"      // Email OTP (passwordless)
            : "emailaddress";  // Email + Password (with JIT migration)

        // Check if user already has the target identity type
        var hasTargetIdentity = user.Identities?.Any(i =>
            i.SignInType?.ToLower() == targetSignInType.ToLower()) ?? false;

        if (!hasTargetIdentity)
        {
            // Determine email to use:
            // 1. Prefer mail field if available
            // 2. Fallback to userPrincipalName if user only has userName + userPrincipalName (no email in B2C)
            var email = user.Mail;

            if (string.IsNullOrEmpty(email))
            {
                // No email in mail field - use userPrincipalName as email
                // This handles B2C users with only userName + userPrincipalName identities
                email = user.UserPrincipalName;
                
                if (_options.VerboseLogging)
                {
                    _logger.LogWarning("User {UPN} has no email in 'mail' field. Using userPrincipalName as email fallback.", 
                        user.UserPrincipalName);
                }
            }

            // Add the appropriate identity based on configuration
            user.Identities ??= new List<ObjectIdentity>();
            
            if (_options.Import.MigrationAttributes.UseEmailOtp)
            {
                // Email OTP (passwordless) - uses federated identity with issuer="mail"
                user.Identities.Add(new ObjectIdentity
                {
                    SignInType = "federated",
                    Issuer = "mail",  // Special issuer for Email OTP
                    IssuerAssignedId = email
                });
                
                if (_options.VerboseLogging)
                {
                    _logger.LogDebug("Added Email OTP identity (federated): {Email}", email);
                }
            }
            else
            {
                // Email + Password (with JIT migration)
                user.Identities.Add(new ObjectIdentity
                {
                    SignInType = "emailAddress",
                    Issuer = _options.ExternalId.TenantDomain,
                    IssuerAssignedId = email
                });
                
                if (_options.VerboseLogging)
                {
                    _logger.LogDebug("Added email identity (password-based): {Email}", email);
                }
            }
        }
    }

    private static string MaskPhoneNumber(string phoneNumber)
    {
        if (string.IsNullOrEmpty(phoneNumber) || phoneNumber.Length < 4)
            return "***";

        // Show last 4 digits only
        return $"***{phoneNumber.Substring(phoneNumber.Length - 4)}";
    }

    private static string GenerateRandomPassword()
    {
        // External ID password requirements:
        // - Minimum 8 characters
        // - At least one uppercase letter
        // - At least one lowercase letter
        // - At least one digit
        // - At least one special character
        
        const string uppercase = "ABCDEFGHJKLMNPQRSTUVWXYZ";
        const string lowercase = "abcdefghijkmnpqrstuvwxyz";
        const string digits = "23456789";
        const string special = "!@#$%^&*";
        const string allChars = uppercase + lowercase + digits + special;
        
        var random = new Random();
        var password = new List<char>();
        
        // Guarantee at least one of each required type
        password.Add(uppercase[random.Next(uppercase.Length)]);
        password.Add(lowercase[random.Next(lowercase.Length)]);
        password.Add(digits[random.Next(digits.Length)]);
        password.Add(special[random.Next(special.Length)]);
        
        // Fill remaining 12 characters randomly
        for (int i = 4; i < 16; i++)
        {
            password.Add(allChars[random.Next(allChars.Length)]);
        }
        
        // Shuffle to avoid predictable pattern (first chars always have one of each type)
        for (int i = password.Count - 1; i > 0; i--)
        {
            int j = random.Next(i + 1);
            (password[i], password[j]) = (password[j], password[i]);
        }
        
        return new string(password.ToArray());
    }

    /// <summary>
    /// Updates extension attributes for duplicate users (users that already exist).
    /// Used when OverwriteExtensionAttributes is enabled.
    /// </summary>
    private async Task<int> UpdateExtensionAttributesForDuplicatesAsync(
        List<UserProfile> duplicateUsers,
        CancellationToken cancellationToken)
    {
        int updateCount = 0;
        var b2cAttr = MigrationExtensionAttributes.GetFullAttributeName(
            _options.ExternalId.ExtensionAppId,
            MigrationExtensionAttributes.B2CObjectId);
        var requireMigrationAttr = GetRequireMigrationAttributeName();

        foreach (var user in duplicateUsers)
        {
            try
            {
                // Find user by UPN using filter
                var filter = $"userPrincipalName eq '{user.UserPrincipalName}'";
                var result = await _externalIdGraphClient.GetUsersAsync(
                    pageSize: 1,
                    select: $"id,{b2cAttr},{requireMigrationAttr}",
                    filter: filter,
                    cancellationToken: cancellationToken);

                var existingUser = result.Items.FirstOrDefault();
                if (existingUser == null)
                {
                    _logger.LogWarning("Could not find existing user {UPN} for extension attribute update", 
                        user.UserPrincipalName);
                    continue;
                }

                // Prepare extension attribute updates
                var updates = new Dictionary<string, object>();

                if (_options.Import.MigrationAttributes.StoreB2CObjectId && user.ExtensionAttributes.ContainsKey(b2cAttr))
                {
                    updates[b2cAttr] = user.ExtensionAttributes[b2cAttr];
                }

                if (_options.Import.MigrationAttributes.SetRequireMigration && user.ExtensionAttributes.ContainsKey(requireMigrationAttr))
                {
                    updates[requireMigrationAttr] = user.ExtensionAttributes[requireMigrationAttr];
                }

                if (updates.Any())
                {
                    await _externalIdGraphClient.UpdateUserAsync(existingUser.Id!, updates, cancellationToken);
                    updateCount++;
                    _logger.LogDebug("Updated extension attributes for user {UPN}", user.UserPrincipalName);
                }
            }
            catch (Exception ex)
            {
                _logger.LogWarning(ex, "Failed to update extension attributes for duplicate user {UPN}", 
                    user.UserPrincipalName);
            }
        }

        return updateCount;
    }
}
