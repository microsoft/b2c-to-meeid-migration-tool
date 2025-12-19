// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

using B2CMigrationKit.Core.Abstractions;
using B2CMigrationKit.Core.Configuration;
using B2CMigrationKit.Core.Models;
using B2CMigrationKit.Core.Services.Orchestrators;
using Jose;
using Microsoft.Azure.Functions.Worker;
using Microsoft.Azure.Functions.Worker.Http;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using System.Net;
using System.Security.Cryptography;
using System.Text.Json;

namespace B2CMigrationKit.Function;

/// <summary>
/// Azure Function for Just-In-Time user migration during login.
/// Invoked by External ID Custom Authentication Extension (OnPasswordSubmit event).
/// </summary>
public class JitAuthenticationFunction
{
    private readonly JitMigrationService _jitService;
    private readonly ISecretProvider? _secretProvider;
    private readonly JitAuthenticationOptions _jitOptions;
    private readonly MigrationOptions _migrationOptions;
    private readonly ILogger<JitAuthenticationFunction> _logger;

    // Cached RSA private key (loaded from Key Vault or inline config)
    private string? _cachedPrivateKey;
    private readonly SemaphoreSlim _keyLoadLock = new(1, 1);

    public JitAuthenticationFunction(
        JitMigrationService jitService,
        IOptions<MigrationOptions> options,
        ILogger<JitAuthenticationFunction> logger,
        ISecretProvider? secretProvider = null)
    {
        _jitService = jitService ?? throw new ArgumentNullException(nameof(jitService));
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
        _secretProvider = secretProvider;
        _migrationOptions = options?.Value ?? throw new ArgumentNullException(nameof(options));
        _jitOptions = options?.Value?.JitAuthentication ?? throw new ArgumentNullException(nameof(options));

        // Validate configuration
        if (_jitOptions.UseKeyVault && _secretProvider == null)
        {
            throw new InvalidOperationException(
                "JIT Authentication is configured to use Key Vault (UseKeyVault=true) but ISecretProvider is not registered. " +
                "Ensure Key Vault is configured in MigrationOptions.KeyVault.");
        }

        if (!_jitOptions.UseKeyVault && string.IsNullOrEmpty(_jitOptions.InlineRsaPrivateKey))
        {
            throw new InvalidOperationException(
                "JIT Authentication is configured to use inline key (UseKeyVault=false) but InlineRsaPrivateKey is not set. " +
                "For local development, provide the RSA private key in configuration.");
        }
    }

    [Function("JitAuthentication")]
    public async Task<HttpResponseData> RunAsync(
        [HttpTrigger(AuthorizationLevel.Anonymous, "get", "post")] HttpRequestData req,
        FunctionContext context)
    {
        var requestId = Guid.NewGuid().ToString();
        var startTime = DateTimeOffset.UtcNow;
        var remoteIp = req.Headers.Contains("X-Forwarded-For")
            ? req.Headers.GetValues("X-Forwarded-For").FirstOrDefault()
            : "unknown";

        _logger.LogInformation(
            "[JIT Function] HTTP {Method} received | RequestId: {RequestId} | RemoteIP: {RemoteIP}",
            req.Method, requestId, remoteIp);

        // Handle GET request - used by External ID to validate the endpoint
        if (req.Method.Equals("GET", StringComparison.OrdinalIgnoreCase))
        {
            _logger.LogInformation("[JIT Function] GET request - Endpoint validation | RequestId: {RequestId}", requestId);
            var response = req.CreateResponse(HttpStatusCode.OK);
            await response.WriteStringAsync("JIT Authentication Endpoint - Ready");
            return response;
        }

        try
        {
            // Parse External ID Custom Authentication Extension request
            var requestBody = await new StreamReader(req.Body).ReadToEndAsync();
            _logger.LogInformation(
                "[JIT Function] Parsing External ID payload | RequestId: {RequestId} | BodyLength: {Length}",
                requestId, requestBody.Length);

            var extRequest = JsonSerializer.Deserialize<CustomAuthenticationExtensionRequest>(
                requestBody,
                new JsonSerializerOptions { PropertyNameCaseInsensitive = true });

            if (extRequest?.Data == null)
            {
                _logger.LogWarning(
                    "[JIT Function] ⚠️ Invalid payload - Missing data object | RequestId: {RequestId}",
                    requestId);

                return await CreateExtensionResponseAsync(req, new JitMigrationResult
                {
                    ActionType = ResponseActionType.Block,
                    Title = "Invalid Request",
                    Message = "The authentication request is malformed."
                });
            }

            // Extract user information from External ID payload
            var userId = extRequest.Data.AuthenticationContext?.User?.Id;
            var userPrincipalName = extRequest.Data.AuthenticationContext?.User?.UserPrincipalName;
            var correlationId = extRequest.Data.AuthenticationContext?.CorrelationId ?? requestId;

            // Extract password - handle both encrypted and plain text contexts
            string? userPassword = null;
            string? nonce = null;

            if (!string.IsNullOrEmpty(extRequest.Data.EncryptedPasswordContext))
            {
                _logger.LogInformation(
                    "[JIT Function] Decrypting password context | CorrelationId: {CorrelationId} | RequestId: {RequestId}",
                    correlationId, requestId);

                (userPassword, nonce) = await DecryptPasswordContext(extRequest.Data.EncryptedPasswordContext, correlationId, requestId);

                if (string.IsNullOrEmpty(userPassword))
                {
                    _logger.LogError(
                        "[JIT Function] Failed to decrypt password context | CorrelationId: {CorrelationId} | RequestId: {RequestId}",
                        correlationId, requestId);

                    return await CreateExtensionResponseAsync(req, new JitMigrationResult
                    {
                        ActionType = ResponseActionType.Block,
                        Title = "Decryption Error",
                        Message = "Unable to process authentication request."
                    }, nonce);
                }
            }
            else
            {
                // Fallback to plain text password context (for testing)
                userPassword = extRequest.Data.PasswordContext?.UserPassword;
                nonce = extRequest.Data.PasswordContext?.Nonce;
            }

            _logger.LogInformation(
                "[JIT Function] Parsed External ID payload | UserId: {UserId} | UPN: {UPN} | CorrelationId: {CorrelationId} | RequestId: {RequestId}",
                userId, userPrincipalName, correlationId, requestId);

            // Validate required fields
            if (string.IsNullOrEmpty(userId) || string.IsNullOrEmpty(userPassword))
            {
                _logger.LogWarning(
                    "[JIT Function] ⚠️ Missing required fields | UserId: {UserId} | HasPassword: {HasPassword} | RequestId: {RequestId}",
                    userId ?? "null", !string.IsNullOrEmpty(userPassword), requestId);

                return await CreateExtensionResponseAsync(req, new JitMigrationResult
                {
                    ActionType = ResponseActionType.Block,
                    Title = "Invalid Request",
                    Message = "Required authentication information is missing."
                }, nonce);
            }

            // For B2C validation, we need the UPN - if not provided, try to construct it
            if (string.IsNullOrEmpty(userPrincipalName))
            {
                _logger.LogWarning(
                    "[JIT Function] ⚠️ UPN not provided in payload | UserId: {UserId} | RequestId: {RequestId}",
                    userId, requestId);

                return await CreateExtensionResponseAsync(req, new JitMigrationResult
                {
                    ActionType = ResponseActionType.Block,
                    Title = "Configuration Error",
                    Message = "Unable to validate credentials. Please contact support."
                }, nonce);
            }

            // Transform External ID UPN to B2C UPN (reverse transformation)
            // Example: user@externalid.onmicrosoft.com → user@b2c.onmicrosoft.com
            var b2cUpn = TransformUpnForB2C(userPrincipalName);

            _logger.LogInformation(
                "[JIT Function] Transformed UPN for B2C validation | ExternalIdUPN: {ExternalIdUPN} | B2CUPN: {B2CUPN} | RequestId: {RequestId}",
                userPrincipalName, b2cUpn, requestId);

            // Perform JIT migration to B2C or whatever 3rp party IDP
            _logger.LogInformation(
                "[JIT Function] Calling JIT migration service | UserId: {UserId} | B2C UPN: {UPN} | CorrelationId: {CorrelationId} | RequestId: {RequestId}",
                userId, b2cUpn, correlationId, requestId);

            var result = await _jitService.MigrateUserAsync(
                userId,
                b2cUpn,
                userPassword,
                correlationId,
                context.CancellationToken);

            var duration = (DateTimeOffset.UtcNow - startTime).TotalMilliseconds;

            _logger.LogInformation(
                "[JIT Function] ✅ JIT migration completed | UserId: {UserId} | Action: {Action} | AlreadyMigrated: {AlreadyMigrated} | Duration: {Duration}ms | Nonce: {NonceStatus} | CorrelationId: {CorrelationId} | RequestId: {RequestId}",
                userId, result.ActionType, result.AlreadyMigrated, duration, !string.IsNullOrEmpty(nonce) ? "✓" : "✗", correlationId, requestId);

            return await CreateExtensionResponseAsync(req, result, nonce);
        }
        catch (JsonException jsonEx)
        {
            var duration = (DateTimeOffset.UtcNow - startTime).TotalMilliseconds;

            _logger.LogError(jsonEx,
                "[JIT Function] ❌ JSON parsing error | Duration: {Duration}ms | RequestId: {RequestId}",
                duration, requestId);

            return await CreateExtensionResponseAsync(req, new JitMigrationResult
            {
                ActionType = ResponseActionType.Block,
                Title = "Request Error",
                Message = "Unable to process authentication request."
            });
        }
        catch (Exception ex)
        {
            var duration = (DateTimeOffset.UtcNow - startTime).TotalMilliseconds;

            _logger.LogError(ex,
                "[JIT Function] ❌ EXCEPTION | Duration: {Duration}ms | RequestId: {RequestId} | ExceptionType: {ExceptionType}",
                duration, requestId, ex.GetType().Name);

            return await CreateExtensionResponseAsync(req, new JitMigrationResult
            {
                ActionType = ResponseActionType.Block,
                Title = "System Error",
                Message = "An error occurred during authentication. Please try again later."
            });
        }
    }

    /// <summary>
    /// Creates Custom Authentication Extension response.
    /// </summary>
    private static async Task<HttpResponseData> CreateExtensionResponseAsync(
        HttpRequestData req,
        JitMigrationResult result,
        string? nonce = null)
    {
        var response = req.CreateResponse(HttpStatusCode.OK);
        response.Headers.Add("Content-Type", "application/json");

        var extResponse = new CustomAuthenticationExtensionResponse(
            result.ActionType,
            result.Title,
            result.Message);

        // Add nonce to response if provided
        if (!string.IsNullOrEmpty(nonce))
        {
            extResponse.Data.Nonce = nonce;
        }

        var json = JsonSerializer.Serialize(extResponse, new JsonSerializerOptions
        {
            PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
            WriteIndented = false
        });

        await response.WriteStringAsync(json);

        return response;
    }

    /// <summary>
    /// Decrypts the encrypted password context from External ID using RSA private key.
    /// The encrypted context is a JWT token encrypted with the public key configured in External ID.
    /// Private key is retrieved from Azure Key Vault or inline configuration.
    /// </summary>
    /// <param name="encryptedContext">The encrypted JWT token from External ID</param>
    /// <param name="correlationId">Correlation ID for logging</param>
    /// <param name="requestId">Request ID for logging</param>
    /// <returns>Tuple containing (password, nonce)</returns>
    private async Task<(string? password, string? nonce)> DecryptPasswordContext(
        string encryptedContext,
        string correlationId,
        string requestId)
    {
        try
        {
            _logger.LogDebug(
                "[JIT Function] Starting password decryption | CorrelationId: {CorrelationId} | RequestId: {RequestId}",
                correlationId, requestId);

            if (string.IsNullOrEmpty(encryptedContext))
            {
                _logger.LogError(
                    "[JIT Function] Encrypted context is null or empty | CorrelationId: {CorrelationId} | RequestId: {RequestId}",
                    correlationId, requestId);
                return (null, null);
            }

            // Get RSA private key (from cache, Key Vault, or inline config)
            var privateKeyPem = await GetPrivateKeyAsync(correlationId, requestId);

            if (string.IsNullOrEmpty(privateKeyPem))
            {
                _logger.LogError(
                    "[JIT Function] Failed to retrieve RSA private key | CorrelationId: {CorrelationId} | RequestId: {RequestId}",
                    correlationId, requestId);
                return (null, null);
            }

            // Create RSA instance and import private key
            using var rsa = RSA.Create();
            rsa.ImportFromPem(privateKeyPem);

            _logger.LogDebug(
                "[JIT Function] RSA key imported, attempting JWT decryption | CorrelationId: {CorrelationId} | RequestId: {RequestId}",
                correlationId, requestId);

            // Step 1: Decrypt JWE using RSA private key
            string decryptedPayload = JWT.Decode(encryptedContext, rsa);

            if (string.IsNullOrEmpty(decryptedPayload))
            {
                _logger.LogError(
                    "[JIT Function] JWT decryption resulted in empty payload | CorrelationId: {CorrelationId} | RequestId: {RequestId}",
                    correlationId, requestId);
                return (null, null);
            }

            _logger.LogDebug(
                "[JIT Function] JWT decrypted successfully (payload length: {Length}), decoding inner JWT | CorrelationId: {CorrelationId} | RequestId: {RequestId}",
                decryptedPayload.Length, correlationId, requestId);

            // Step 2: Decode the inner JWS (no encryption, just base64)
            string jsonPayload = JWT.Decode(decryptedPayload, null, JwsAlgorithm.none);

            if (string.IsNullOrEmpty(jsonPayload))
            {
                _logger.LogError(
                    "[JIT Function] Inner JWT decode resulted in empty payload | CorrelationId: {CorrelationId} | RequestId: {RequestId}",
                    correlationId, requestId);
                return (null, null);
            }

            _logger.LogDebug(
                "[JIT Function] Inner JWT decoded successfully, parsing JSON | CorrelationId: {CorrelationId} | RequestId: {RequestId}",
                correlationId, requestId);

            // Parse the final JSON payload
            var payloadDoc = JsonDocument.Parse(jsonPayload);
            var root = payloadDoc.RootElement;

            // Extract password and nonce from payload
            string? password = root.TryGetProperty("user-password", out var pwdElement) 
                ? pwdElement.GetString() 
                : null;

            string? nonce = root.TryGetProperty("nonce", out var nonceElement) 
                ? nonceElement.GetString() 
                : null;

            _logger.LogInformation(
                "[JIT Function] Decryption complete | Password: {PasswordStatus}, Nonce: {NonceStatus} | CorrelationId: {CorrelationId} | RequestId: {RequestId}",
                !string.IsNullOrEmpty(password) ? "✓" : "✗",
                !string.IsNullOrEmpty(nonce) ? "✓" : "✗",
                correlationId, requestId);

            return (password, nonce);
        }
        catch (Jose.JoseException joseEx)
        {
            _logger.LogError(joseEx,
                "[JIT Function] Jose JWT library error during decryption | CorrelationId: {CorrelationId} | RequestId: {RequestId}",
                correlationId, requestId);
            return (null, null);
        }
        catch (JsonException jsonEx)
        {
            _logger.LogError(jsonEx,
                "[JIT Function] JSON parsing error after decryption | CorrelationId: {CorrelationId} | RequestId: {RequestId}",
                correlationId, requestId);
            return (null, null);
        }
        catch (CryptographicException cryptoEx)
        {
            _logger.LogError(cryptoEx,
                "[JIT Function] Cryptographic error (check private key format) | CorrelationId: {CorrelationId} | RequestId: {RequestId}",
                correlationId, requestId);
            return (null, null);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex,
                "[JIT Function] Unexpected error decrypting password context | CorrelationId: {CorrelationId} | RequestId: {RequestId}",
                correlationId, requestId);
            return (null, null);
        }
    }

    /// <summary>
    /// Gets the RSA private key from cache, Key Vault, or inline configuration.
    /// Implements caching to reduce Key Vault calls.
    /// </summary>
    private async Task<string?> GetPrivateKeyAsync(string correlationId, string requestId)
    {
        // Return cached key if available and caching is enabled
        if (_jitOptions.CachePrivateKey && _cachedPrivateKey != null)
        {
            _logger.LogDebug(
                "[JIT Function] Using cached RSA private key | CorrelationId: {CorrelationId} | RequestId: {RequestId}",
                correlationId, requestId);
            return _cachedPrivateKey;
        }

        // Use semaphore to prevent concurrent Key Vault calls during first load
        await _keyLoadLock.WaitAsync();
        try
        {
            // Double-check after acquiring lock
            if (_jitOptions.CachePrivateKey && _cachedPrivateKey != null)
            {
                return _cachedPrivateKey;
            }

            string? privateKey;

            if (_jitOptions.UseKeyVault)
            {
                // Retrieve from Azure Key Vault
                _logger.LogInformation(
                    "[JIT Function] Retrieving RSA private key from Key Vault: {KeyName} | CorrelationId: {CorrelationId} | RequestId: {RequestId}",
                    _jitOptions.RsaKeyName, correlationId, requestId);

                privateKey = await _secretProvider!.GetSecretAsync(_jitOptions.RsaKeyName);

                if (string.IsNullOrEmpty(privateKey))
                {
                    _logger.LogError(
                        "[JIT Function] Key Vault returned empty private key for: {KeyName} | CorrelationId: {CorrelationId} | RequestId: {RequestId}",
                        _jitOptions.RsaKeyName, correlationId, requestId);
                    return null;
                }

                _logger.LogInformation(
                    "[JIT Function] ✓ RSA private key retrieved from Key Vault successfully | CorrelationId: {CorrelationId} | RequestId: {RequestId}",
                    correlationId, requestId);
            }
            else
            {
                // Use inline key from configuration (local development only)
                _logger.LogWarning(
                    "[JIT Function] Using inline RSA private key from configuration (local development mode) | CorrelationId: {CorrelationId} | RequestId: {RequestId}",
                    correlationId, requestId);

                privateKey = _jitOptions.InlineRsaPrivateKey;
            }

            // Cache the key if caching is enabled
            if (_jitOptions.CachePrivateKey && !string.IsNullOrEmpty(privateKey))
            {
                _cachedPrivateKey = privateKey;
                _logger.LogDebug(
                    "[JIT Function] RSA private key cached in memory | CorrelationId: {CorrelationId} | RequestId: {RequestId}",
                    correlationId, requestId);
            }

            return privateKey;
        }
        finally
        {
            _keyLoadLock.Release();
        }
    }

    /// <summary>
    /// Transform External ID UPN to B2C UPN by replacing domain.
    /// This is the inverse transformation of ImportOrchestrator.TransformUpnForExternalId.
    /// Examples:
    ///   user@externalid.onmicrosoft.com → user@b2c.onmicrosoft.com
    ///   047102b7-221a-4fcf-9bf6-a179e37efd62@externalid.onmicrosoft.com → 047102b7-221a-4fcf-9bf6-a179e37efd62@b2c.onmicrosoft.com
    /// </summary>
    /// <param name="externalIdUpn">UPN from External ID (with External ID domain)</param>
    /// <returns>UPN with B2C domain for ROPC validation</returns>
    private string TransformUpnForB2C(string externalIdUpn)
    {
        if (string.IsNullOrEmpty(externalIdUpn))
            return externalIdUpn;

        var atIndex = externalIdUpn.IndexOf('@');
        if (atIndex == -1)
            return externalIdUpn; // Invalid format, return as-is

        // Extract local part (everything before @)
        var localPart = externalIdUpn.Substring(0, atIndex);

        // Replace External ID domain with B2C domain
        var b2cUpn = $"{localPart}@{_migrationOptions.B2C.TenantDomain}";

        _logger.LogDebug(
            "[JIT Function] UPN domain transformation | Input: {Input} | Output: {Output}",
            externalIdUpn, b2cUpn);

        return b2cUpn;
    }
}
