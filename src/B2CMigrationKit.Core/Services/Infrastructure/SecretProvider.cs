// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
using Azure.Identity;
using Azure.Security.KeyVault.Secrets;
using B2CMigrationKit.Core.Abstractions;
using B2CMigrationKit.Core.Configuration;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using System.Collections.Concurrent;

namespace B2CMigrationKit.Core.Services.Infrastructure;

/// <summary>
/// Provides access to secrets stored in Azure Key Vault with in-memory caching.
/// </summary>
public class SecretProvider : ISecretProvider
{
    private readonly SecretClient _client;
    private readonly ILogger<SecretProvider> _logger;
    private readonly KeyVaultOptions _options;
    private readonly ConcurrentDictionary<string, (string Value, DateTimeOffset ExpiresAt)> _cache = new();

    public SecretProvider(
        IOptions<KeyVaultOptions> options,
        ILogger<SecretProvider> logger)
    {
        _options = options?.Value ?? throw new ArgumentNullException(nameof(options));
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));

        var credential = _options.UseManagedIdentity
            ? new DefaultAzureCredential()
            : throw new NotSupportedException("Only Managed Identity authentication is supported");

        _client = new SecretClient(new Uri(_options.VaultUri), credential);

        _logger.LogInformation("Secret provider initialized for Key Vault: {VaultUri}", _options.VaultUri);
    }

    public async Task<string> GetSecretAsync(string secretName, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrEmpty(secretName))
        {
            throw new ArgumentException("Secret name cannot be null or empty", nameof(secretName));
        }

        // Check cache
        if (_cache.TryGetValue(secretName, out var cachedSecret))
        {
            if (cachedSecret.ExpiresAt > DateTimeOffset.UtcNow)
            {
                _logger.LogDebug("Returning cached secret: {SecretName}", secretName);
                return cachedSecret.Value;
            }
            else
            {
                _cache.TryRemove(secretName, out _);
            }
        }

        try
        {
            _logger.LogDebug("Fetching secret from Key Vault: {SecretName}", secretName);

            var secret = await _client.GetSecretAsync(secretName, cancellationToken: cancellationToken);

            var expiresAt = DateTimeOffset.UtcNow.AddMinutes(_options.SecretCacheDurationMinutes);
            _cache[secretName] = (secret.Value.Value, expiresAt);

            _logger.LogInformation("Successfully retrieved secret: {SecretName}", secretName);

            return secret.Value.Value;
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to retrieve secret: {SecretName}", secretName);
            throw;
        }
    }

    public async Task SetSecretAsync(string secretName, string secretValue, CancellationToken cancellationToken = default)
    {
        if (string.IsNullOrEmpty(secretName))
        {
            throw new ArgumentException("Secret name cannot be null or empty", nameof(secretName));
        }

        if (string.IsNullOrEmpty(secretValue))
        {
            throw new ArgumentException("Secret value cannot be null or empty", nameof(secretValue));
        }

        try
        {
            _logger.LogDebug("Setting secret in Key Vault: {SecretName}", secretName);

            await _client.SetSecretAsync(secretName, secretValue, cancellationToken);

            // Invalidate cache
            _cache.TryRemove(secretName, out _);

            _logger.LogInformation("Successfully set secret: {SecretName}", secretName);
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to set secret: {SecretName}", secretName);
            throw;
        }
    }
}
