// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
using Azure.Core;
using Azure.Identity;
using B2CMigrationKit.Core.Abstractions;
using B2CMigrationKit.Core.Configuration;
using Microsoft.Extensions.Logging;

namespace B2CMigrationKit.Core.Services.Infrastructure;

/// <summary>
/// Manages Azure AD app registration credential for Graph API access.
/// </summary>
public class CredentialManager : ICredentialManager
{
    private readonly TokenCredential _credential;
    private readonly ILogger<CredentialManager> _logger;

    public CredentialManager(
        AppRegistration appRegistration,
        string tenantId,
        ISecretProvider? secretProvider,
        ILogger<CredentialManager> logger)
    {
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));

        if (appRegistration == null)
        {
            throw new ArgumentNullException(nameof(appRegistration));
        }

        if (!appRegistration.Enabled)
        {
            throw new InvalidOperationException("App registration is disabled");
        }

        try
        {
            if (!string.IsNullOrEmpty(appRegistration.CertificateThumbprint))
            {
                // Certificate-based authentication
                _credential = new ClientCertificateCredential(
                    tenantId,
                    appRegistration.ClientId,
                    appRegistration.CertificateThumbprint);

                _logger.LogInformation("Initialized credential for app {ClientId} using certificate",
                    appRegistration.ClientId);
            }
            else if (!string.IsNullOrEmpty(appRegistration.ClientSecret))
            {
                // Direct secret (for local development)
                _credential = new ClientSecretCredential(
                    tenantId,
                    appRegistration.ClientId,
                    appRegistration.ClientSecret);

                _logger.LogInformation("Initialized credential for app {ClientId} using direct secret",
                    appRegistration.ClientId);
            }
            else if (!string.IsNullOrEmpty(appRegistration.ClientSecretName) && secretProvider != null)
            {
                // Get secret from Key Vault
                var secret = secretProvider.GetSecretAsync(appRegistration.ClientSecretName)
                    .GetAwaiter().GetResult();
                _credential = new ClientSecretCredential(
                    tenantId,
                    appRegistration.ClientId,
                    secret);

                _logger.LogInformation("Initialized credential for app {ClientId} using Key Vault secret",
                    appRegistration.ClientId);
            }
            else
            {
                // Fall back to Managed Identity
                _credential = new DefaultAzureCredential();
                _logger.LogInformation("Initialized credential using DefaultAzureCredential (Managed Identity)");
            }
        }
        catch (Exception ex)
        {
            _logger.LogError(ex, "Failed to initialize credential for app {ClientId}",
                appRegistration.ClientId);
            throw;
        }
    }

    public int CredentialCount => 1;

    public TokenCredential GetNextCredential()
    {
        return _credential;
    }

    public TokenCredential GetCredential(int index)
    {
        if (index != 0)
        {
            throw new ArgumentOutOfRangeException(nameof(index),
                "Only one credential is configured. Index must be 0.");
        }

        return _credential;
    }

    public void ReportThrottling(int credentialIndex, int retryAfterSeconds)
    {
        // No-op for single credential - throttling is handled by Graph SDK retry policy
        _logger.LogWarning("Throttled for {Seconds} seconds. Retry will be handled by Graph SDK.",
            retryAfterSeconds);
    }
}
