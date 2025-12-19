// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
using Azure.Core;
using B2CMigrationKit.Core.Abstractions;
using Microsoft.Graph;
using Microsoft.Extensions.Logging;

namespace B2CMigrationKit.Core.Services.Infrastructure;

/// <summary>
/// Factory for creating Microsoft Graph clients with credential rotation support.
/// </summary>
public class GraphClientFactory
{
    private readonly ICredentialManager _credentialManager;
    private readonly ILogger _logger;
    private readonly ITelemetryService _telemetry;

    public GraphClientFactory(
        ICredentialManager credentialManager,
        ILogger<GraphClientFactory> logger,
        ITelemetryService telemetry)
    {
        _credentialManager = credentialManager ?? throw new ArgumentNullException(nameof(credentialManager));
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
        _telemetry = telemetry ?? throw new ArgumentNullException(nameof(telemetry));
    }

    public GraphServiceClient CreateClient(string[] scopes)
    {
        var credential = _credentialManager.GetNextCredential();

        return new GraphServiceClient(credential, scopes);
    }
}
