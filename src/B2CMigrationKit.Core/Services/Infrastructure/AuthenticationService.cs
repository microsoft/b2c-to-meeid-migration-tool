// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
using B2CMigrationKit.Core.Abstractions;
using B2CMigrationKit.Core.Configuration;
using B2CMigrationKit.Core.Models;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using System.Net.Http.Json;
using System.Text.RegularExpressions;

namespace B2CMigrationKit.Core.Services.Infrastructure;

/// <summary>
/// Provides authentication services for validating credentials during JIT migration.
/// </summary>
public class AuthenticationService : IAuthenticationService
{
    private readonly HttpClient _httpClient;
    private readonly B2COptions _b2cOptions;
    private readonly ExternalIdOptions _externalIdOptions;
    private readonly ILogger<AuthenticationService> _logger;

    public AuthenticationService(
        IHttpClientFactory httpClientFactory,
        IOptions<MigrationOptions> options,
        ILogger<AuthenticationService> logger)
    {
        _httpClient = httpClientFactory?.CreateClient() ?? throw new ArgumentNullException(nameof(httpClientFactory));
        _b2cOptions = options?.Value?.B2C ?? throw new ArgumentNullException(nameof(options));
        _externalIdOptions = options?.Value?.ExternalId ?? throw new ArgumentNullException(nameof(options));
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
    }

    public async Task<AuthenticationResult> ValidateCredentialsAsync(
        string username,
        string password,
        CancellationToken cancellationToken = default)
    {
        try
        {
            // Use ROPC flow to validate credentials directly against Entra ID (not B2C)
            // This bypasses B2C policies and authenticates directly to the underlying directory
            var tokenEndpoint = $"https://login.microsoftonline.com/{_b2cOptions.TenantId}/oauth2/v2.0/token";

            var appReg = _b2cOptions.AppRegistration;
            if (appReg == null || !appReg.Enabled)
            {
                throw new InvalidOperationException("B2C app registration is not configured or disabled");
            }

            if (string.IsNullOrEmpty(appReg.ClientSecret))
            {
                throw new InvalidOperationException("Client secret is required for Entra ID ROPC authentication");
            }

            var request = new Dictionary<string, string>
            {
                { "client_id", appReg.ClientId },
                { "scope", "openid" },
                { "grant_type", "password" },
                { "username", username },
                { "password", password },
                { "NCA", "1" },
                { "client_secret", appReg.ClientSecret }
            };

            _logger.LogDebug("Validating credentials for user {Username} via Entra ID ROPC", username);

            var response = await _httpClient.PostAsync(
                tokenEndpoint,
                new FormUrlEncodedContent(request),
                cancellationToken);

            if (response.IsSuccessStatusCode)
            {
                _logger.LogInformation("Credential validation successful for user {Username}", username);
                return AuthenticationResult.CreateSuccess(username);
            }

            var errorContent = await response.Content.ReadAsStringAsync(cancellationToken);
            _logger.LogWarning("Credential validation failed for user {Username}: HTTP {StatusCode} - {Error}",
                username, (int)response.StatusCode, errorContent);

            return AuthenticationResult.CreateFailure(
                "invalid_credentials",
                "The username or password is incorrect");
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Error validating credentials for user {Username}", username);
            return AuthenticationResult.CreateFailure(
                "authentication_error",
                ex.Message);
        }
    }

    public PasswordValidationResult ValidatePasswordComplexity(string password)
    {
        var policy = _externalIdOptions.PasswordPolicy;
        var errors = new List<string>();
        var result = new PasswordValidationResult();

        if (password.Length < policy.MinLength)
        {
            errors.Add($"Password must be at least {policy.MinLength} characters long");
        }
        else
        {
            result.MeetsLengthRequirement = true;
        }

        if (policy.RequireUppercase && !Regex.IsMatch(password, "[A-Z]"))
        {
            errors.Add("Password must contain at least one uppercase letter");
        }
        else if (policy.RequireUppercase)
        {
            result.HasUppercase = true;
        }

        if (policy.RequireLowercase && !Regex.IsMatch(password, "[a-z]"))
        {
            errors.Add("Password must contain at least one lowercase letter");
        }
        else if (policy.RequireLowercase)
        {
            result.HasLowercase = true;
        }

        if (policy.RequireDigit && !Regex.IsMatch(password, "[0-9]"))
        {
            errors.Add("Password must contain at least one digit");
        }
        else if (policy.RequireDigit)
        {
            result.HasDigit = true;
        }

        if (policy.RequireSpecialCharacter)
        {
            var specialChars = Regex.Escape(policy.AllowedSpecialCharacters);
            if (!Regex.IsMatch(password, $"[{specialChars}]"))
            {
                errors.Add("Password must contain at least one special character");
            }
            else
            {
                result.HasSpecialCharacter = true;
            }
        }

        result.IsValid = !errors.Any();
        result.Errors = errors;

        return result;
    }
}
