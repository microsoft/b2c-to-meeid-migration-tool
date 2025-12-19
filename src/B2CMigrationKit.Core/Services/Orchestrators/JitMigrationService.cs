// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
using B2CMigrationKit.Core.Abstractions;
using B2CMigrationKit.Core.Configuration;
using B2CMigrationKit.Core.Models;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace B2CMigrationKit.Core.Services.Orchestrators;

/// <summary>
/// Handles Just-In-Time migration of user credentials during first login.
/// </summary>
public class JitMigrationService
{
    private readonly IAuthenticationService _authService;
    private readonly IGraphClient _externalIdGraphClient;
    private readonly ITelemetryService _telemetry;
    private readonly ILogger<JitMigrationService> _logger;
    private readonly MigrationOptions _options;

    public JitMigrationService(
        IAuthenticationService authService,
        IGraphClient externalIdGraphClient,
        ITelemetryService telemetry,
        IOptions<MigrationOptions> options,
        ILogger<JitMigrationService> logger)
    {
        _authService = authService ?? throw new ArgumentNullException(nameof(authService));
        _externalIdGraphClient = externalIdGraphClient ?? throw new ArgumentNullException(nameof(externalIdGraphClient));
        _telemetry = telemetry ?? throw new ArgumentNullException(nameof(telemetry));
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
        _options = options?.Value ?? throw new ArgumentNullException(nameof(options));
    }

    /// <summary>
    /// Performs JIT migration for a user attempting to log in.
    /// Called by External ID Custom Authentication Extension ONLY for users with RequiresMigration=true.
    /// 
    /// CRITICAL: Must complete within 2 seconds (External ID timeout).
    /// Strategy: Validate credentials synchronously, update migration status asynchronously (fire-and-forget).
    /// 
    /// When we return MigratePassword action, External ID updates the user's password.
    /// We also need to mark RequiresMigration=false to prevent future JIT calls.
    /// </summary>
    /// <param name="userId">External ID user ObjectId (from payload)</param>
    /// <param name="userPrincipalName">User UPN for B2C validation</param>
    /// <param name="password">Password provided by user during login</param>
    /// <param name="correlationId">Optional correlation ID from External ID payload</param>
    /// <param name="cancellationToken">Cancellation token</param>
    public async Task<JitMigrationResult> MigrateUserAsync(
        string userId,
        string userPrincipalName,
        string password,
        string? correlationId = null,
        CancellationToken cancellationToken = default)
    {
        var startTime = DateTimeOffset.UtcNow;
        correlationId ??= Guid.NewGuid().ToString();

        try
        {
            _logger.LogInformation(
                "[JIT Migration] Starting | UserId: {UserId} | UPN: {UPN} | CorrelationId: {CorrelationId}",
                userId, userPrincipalName, correlationId);

            _telemetry.TrackEvent("JIT.Started", new Dictionary<string, string>
            {
                { "UserId", userId },
                { "UserPrincipalName", userPrincipalName },
                { "CorrelationId", correlationId },
                { "Timestamp", startTime.ToString("o") }
            });

            // Step 1: Validate credentials against B2C using ROPC
            var step1Start = DateTimeOffset.UtcNow;
            double step1Duration;
            
            if (_options.JitAuthentication.TestMode)
            {
                _logger.LogWarning("[JIT Migration] [TEST MODE] Step 1/3: SKIPPING B2C credential validation - ALL PASSWORDS ACCEPTED | UPN: {UPN}", userPrincipalName);
                step1Duration = (DateTimeOffset.UtcNow - step1Start).TotalMilliseconds;
            }
            else
            {
                _logger.LogInformation("[JIT Migration] Step 1/3: Validating credentials against B2C ROPC | UPN: {UPN}", userPrincipalName);
                
                var authResult = await _authService.ValidateCredentialsAsync(userPrincipalName, password, cancellationToken);
                
                if (authResult == null || !authResult.Success)
                {
                    step1Duration = (DateTimeOffset.UtcNow - step1Start).TotalMilliseconds;
                    _logger.LogWarning(
                        "[JIT Migration] ❌ Authentication FAILED - Invalid B2C credentials | UPN: {UPN} | Duration: {Duration}ms | CorrelationId: {CorrelationId}",
                        userPrincipalName, step1Duration, correlationId);
                    
                    _telemetry.TrackEvent("JIT.ValidationFailed", new Dictionary<string, string>
                    {
                        { "UserId", userId },
                        { "UserPrincipalName", userPrincipalName },
                        { "CorrelationId", correlationId },
                        { "Reason", "InvalidCredentials" },
                        { "DurationMs", step1Duration.ToString() }
                    });
                    
                    return new JitMigrationResult
                    {
                        ActionType = ResponseActionType.Block,
                        Title = "Authentication Failed",
                        Message = "The credentials you provided are incorrect."
                    };
                }
                
                _logger.LogInformation("[JIT Migration] ✓ B2C credentials validated successfully | UPN: {UPN}", userPrincipalName);
                step1Duration = (DateTimeOffset.UtcNow - step1Start).TotalMilliseconds;
            }

            // Step 2: Validate password complexity for External ID
            var step2Start = DateTimeOffset.UtcNow;
            double step2Duration;
            
            if (_options.JitAuthentication.TestMode)
            {
                _logger.LogWarning("[JIT Migration] [TEST MODE] Step 2/3: SKIPPING password complexity validation");
                step2Duration = (DateTimeOffset.UtcNow - step2Start).TotalMilliseconds;
            }
            else
            {
                _logger.LogInformation("[JIT Migration] Step 2/3: Validating password complexity for External ID");
                
                if (!IsPasswordComplex(password))
                {
                    step2Duration = (DateTimeOffset.UtcNow - step2Start).TotalMilliseconds;
                    _logger.LogWarning(
                        "[JIT Migration] ❌ Password does not meet complexity requirements | UPN: {UPN} | Duration: {Duration}ms | CorrelationId: {CorrelationId}",
                        userPrincipalName, step2Duration, correlationId);
                    
                    _telemetry.TrackEvent("JIT.ValidationFailed", new Dictionary<string, string>
                    {
                        { "UserId", userId },
                        { "UserPrincipalName", userPrincipalName },
                        { "CorrelationId", correlationId },
                        { "Reason", "PasswordComplexity" },
                        { "DurationMs", step2Duration.ToString() }
                    });
                    
                    return new JitMigrationResult
                    {
                        ActionType = ResponseActionType.Block,
                        Title = "Password Requirements Not Met",
                        Message = "Your password does not meet the required complexity standards."
                    };
                }
                
                _logger.LogInformation("[JIT Migration] ✓ Password complexity validated | UPN: {UPN}", userPrincipalName);
                step2Duration = (DateTimeOffset.UtcNow - step2Start).TotalMilliseconds;
            }

            // NOTE: External ID automatically updates the migration attribute to false when MigratePassword action is returned
            // No manual update needed

            var totalDuration = (DateTimeOffset.UtcNow - startTime).TotalMilliseconds;

            _logger.LogInformation(
                "[JIT Migration] ✅ SUCCESS - Returning MigratePassword action | UserId: {UserId} | UPN: {UPN} | Total: {Total}ms (Step1: {Step1}ms, Step2: {Step2}ms) | CorrelationId: {CorrelationId}",
                userId, userPrincipalName, totalDuration, step1Duration, step2Duration, correlationId);

            _logger.LogInformation(
                "[JIT Migration] → External ID will update password and migration attribute automatically.");

            _telemetry.TrackEvent("JIT.MigrationCompleted", new Dictionary<string, string>
            {
                { "UserId", userId },
                { "UserPrincipalName", userPrincipalName },
                { "CorrelationId", correlationId },
                { "TotalDurationMs", totalDuration.ToString() },
                { "Step1DurationMs", step1Duration.ToString() },
                { "Step2DurationMs", step2Duration.ToString() },
                { "Timestamp", DateTimeOffset.UtcNow.ToString("o") }
            });

            return new JitMigrationResult
            {
                ActionType = ResponseActionType.MigratePassword
            };
        }
        catch (Exception ex)
        {
            var duration = (DateTimeOffset.UtcNow - startTime).TotalMilliseconds;

            _logger.LogError(ex,
                "[JIT Migration] ❌ EXCEPTION - Unexpected error | UserId: {UserId} | UPN: {UPN} | Duration: {Duration}ms | CorrelationId: {CorrelationId}",
                userId, userPrincipalName, duration, correlationId);

            _telemetry.TrackException(ex, new Dictionary<string, string>
            {
                { "UserId", userId },
                { "UserPrincipalName", userPrincipalName },
                { "CorrelationId", correlationId },
                { "DurationMs", duration.ToString() },
                { "ExceptionType", ex.GetType().Name }
            });

            return new JitMigrationResult
            {
                ActionType = ResponseActionType.Block,
                Title = "System Error",
                Message = "An error occurred during authentication. Please try again later."
            };
        }
    }

    /// <summary>
    /// Validates password complexity for External ID requirements.
    /// </summary>
    private bool IsPasswordComplex(string password)
    {
        if (string.IsNullOrEmpty(password))
            return false;

        // External ID password requirements:
        // - At least 8 characters
        // - Contains uppercase letter
        // - Contains lowercase letter
        // - Contains digit
        // - Contains special character (non-alphanumeric)
        return password.Length >= 8 &&
               password.Any(char.IsUpper) &&
               password.Any(char.IsLower) &&
               password.Any(char.IsDigit) &&
               password.Any(ch => !char.IsLetterOrDigit(ch));
    }
}

/// <summary>
/// Result of a JIT migration attempt.
/// </summary>
public class JitMigrationResult
{
    public ResponseActionType ActionType { get; set; }
    public string? Title { get; set; }
    public string? Message { get; set; }
    public bool AlreadyMigrated { get; set; }
}
