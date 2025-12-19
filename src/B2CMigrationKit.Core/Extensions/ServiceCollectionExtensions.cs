// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
using B2CMigrationKit.Core.Abstractions;
using B2CMigrationKit.Core.Configuration;
using B2CMigrationKit.Core.Services.Infrastructure;
using B2CMigrationKit.Core.Services.Observability;
using B2CMigrationKit.Core.Services.Orchestrators;
using Microsoft.ApplicationInsights;
using Microsoft.ApplicationInsights.Extensibility;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;

namespace B2CMigrationKit.Core.Extensions;

/// <summary>
/// Extension methods for registering Core services in the DI container.
/// </summary>
public static class ServiceCollectionExtensions
{
    /// <summary>
    /// Registers all Core library services with the DI container.
    /// </summary>
    public static IServiceCollection AddMigrationKitCore(
        this IServiceCollection services,
        IConfiguration configuration)
    {
        // Register configuration
        services.Configure<MigrationOptions>(configuration.GetSection(MigrationOptions.SectionName));
        services.Configure<StorageOptions>(configuration.GetSection($"{MigrationOptions.SectionName}:Storage"));
        services.Configure<RetryOptions>(configuration.GetSection($"{MigrationOptions.SectionName}:Retry"));
        services.Configure<TelemetryOptions>(configuration.GetSection($"{MigrationOptions.SectionName}:Telemetry"));

        // Register Application Insights (if configured)
        var telemetryOptions = configuration.GetSection($"{MigrationOptions.SectionName}:Telemetry").Get<TelemetryOptions>();
        if (telemetryOptions?.UseApplicationInsights == true && !string.IsNullOrEmpty(telemetryOptions.ConnectionString))
        {
            var telemetryConfig = new TelemetryConfiguration
            {
                ConnectionString = telemetryOptions.ConnectionString
            };

            // Note: Sampling is best configured in Application Insights portal or via adaptive sampling
            // For programmatic sampling, add Microsoft.ApplicationInsights.WindowsServer NuGet package

            services.AddSingleton(telemetryConfig);
            services.AddSingleton<TelemetryClient>();
        }

        // Register infrastructure services
        services.AddSingleton<ITelemetryService, TelemetryService>();
        services.AddSingleton<IRsaKeyManager, RsaKeyManager>();

        // Register Key Vault (if configured)
        var kvOptions = configuration.GetSection("Migration:KeyVault").Get<KeyVaultOptions>();
        if (kvOptions != null && kvOptions.Enabled && !string.IsNullOrEmpty(kvOptions.VaultUri))
        {
            services.AddSingleton<ISecretProvider, SecretProvider>();
        }

        // Register Azure Storage clients
        services.AddSingleton<IBlobStorageClient, BlobStorageClient>();
        services.AddSingleton<IQueueClient, QueueClient>();

        // Register B2C Credential Manager
        services.AddSingleton<ICredentialManager>(sp =>
        {
            var options = sp.GetRequiredService<IOptions<MigrationOptions>>().Value;
            var logger = sp.GetRequiredService<ILogger<CredentialManager>>();
            var secretProvider = sp.GetService<ISecretProvider>();

            return new CredentialManager(
                options.B2C.AppRegistration,
                options.B2C.TenantId,
                secretProvider,
                logger);
        });

        // Register External ID Credential Manager
        services.AddSingleton<ICredentialManager>(sp =>
        {
            var options = sp.GetRequiredService<IOptions<MigrationOptions>>().Value;
            var logger = sp.GetRequiredService<ILogger<CredentialManager>>();
            var secretProvider = sp.GetService<ISecretProvider>();

            return new CredentialManager(
                options.ExternalId.AppRegistration,
                options.ExternalId.TenantId,
                secretProvider,
                logger);
        });

        // Register Graph clients
        services.AddHttpClient();

        services.AddScoped<IGraphClient>(sp =>
        {
            var options = sp.GetRequiredService<IOptions<MigrationOptions>>().Value;
            // Get B2C credential manager (first registered)
            var credManager = sp.GetRequiredService<IEnumerable<ICredentialManager>>().First();
            var telemetry = sp.GetRequiredService<ITelemetryService>();
            var factoryLogger = sp.GetRequiredService<ILogger<GraphClientFactory>>();
            var clientLogger = sp.GetRequiredService<ILogger<GraphClient>>();

            var factory = new GraphClientFactory(credManager, factoryLogger, telemetry);
            var graphServiceClient = factory.CreateClient(options.B2C.Scopes);

            return new GraphClient(graphServiceClient, sp.GetRequiredService<IOptions<RetryOptions>>(), clientLogger, telemetry);
        });

        // Register authentication service
        services.AddScoped<IAuthenticationService, AuthenticationService>();

        // Register orchestrators and services
        services.AddScoped<ExportOrchestrator>();

        // Register ImportOrchestrator with External ID Graph client
        services.AddScoped<ImportOrchestrator>(sp =>
        {
            var options = sp.GetRequiredService<IOptions<MigrationOptions>>().Value;
            // Get External ID credential manager (second registered)
            var credManager = sp.GetRequiredService<IEnumerable<ICredentialManager>>().Last();
            var telemetry = sp.GetRequiredService<ITelemetryService>();
            var factoryLogger = sp.GetRequiredService<ILogger<GraphClientFactory>>();
            var clientLogger = sp.GetRequiredService<ILogger<GraphClient>>();
            var retryOptions = sp.GetRequiredService<IOptions<RetryOptions>>();
            var blobClient = sp.GetRequiredService<IBlobStorageClient>();
            var orchestratorLogger = sp.GetRequiredService<ILogger<ImportOrchestrator>>();

            var factory = new GraphClientFactory(credManager, factoryLogger, telemetry);
            var graphServiceClient = factory.CreateClient(options.ExternalId.Scopes);
            var graphClient = new GraphClient(graphServiceClient, retryOptions, clientLogger, telemetry);

            return new ImportOrchestrator(graphClient, blobClient, telemetry, Options.Create(options), orchestratorLogger);
        });

        // Register JitMigrationService with External ID Graph client
        services.AddScoped<JitMigrationService>(sp =>
        {
            var options = sp.GetRequiredService<IOptions<MigrationOptions>>().Value;
            var authService = sp.GetRequiredService<IAuthenticationService>();
            var telemetry = sp.GetRequiredService<ITelemetryService>();
            var logger = sp.GetRequiredService<ILogger<JitMigrationService>>();

            // Create External ID credential manager
            var secretProvider = sp.GetService<ISecretProvider>();
            var credManagerLogger = sp.GetRequiredService<ILogger<CredentialManager>>();
            var externalIdCredManager = new CredentialManager(
                options.ExternalId.AppRegistration,
                options.ExternalId.TenantId,
                secretProvider,
                credManagerLogger);

            // Create External ID Graph client
            var factoryLogger = sp.GetRequiredService<ILogger<GraphClientFactory>>();
            var clientLogger = sp.GetRequiredService<ILogger<GraphClient>>();
            var retryOptions = sp.GetRequiredService<IOptions<RetryOptions>>();

            var factory = new GraphClientFactory(externalIdCredManager, factoryLogger, telemetry);
            var graphServiceClient = factory.CreateClient(options.ExternalId.Scopes);
            var externalIdGraphClient = new GraphClient(graphServiceClient, retryOptions, clientLogger, telemetry);

            return new JitMigrationService(authService, externalIdGraphClient, telemetry, Options.Create(options), logger);
        });

        services.AddScoped<ProfileSyncService>();

        return services;
    }

    /// <summary>
    /// Registers B2C-specific Graph client.
    /// </summary>
    public static IServiceCollection AddB2CGraphClient(this IServiceCollection services)
    {
        services.AddScoped<IGraphClient>(sp =>
        {
            var options = sp.GetRequiredService<IOptions<MigrationOptions>>().Value;
            var credManager = sp.GetRequiredService<IEnumerable<ICredentialManager>>()
                .First(); // B2C credential manager
            var telemetry = sp.GetRequiredService<ITelemetryService>();
            var factoryLogger = sp.GetRequiredService<ILogger<GraphClientFactory>>();
            var clientLogger = sp.GetRequiredService<ILogger<GraphClient>>();
            var retryOptions = Options.Create(options.Retry);

            var factory = new GraphClientFactory(credManager, factoryLogger, telemetry);
            var graphServiceClient = factory.CreateClient(options.B2C.Scopes);

            return new GraphClient(graphServiceClient, retryOptions, clientLogger, telemetry);
        });

        return services;
    }

    /// <summary>
    /// Registers External ID-specific Graph client.
    /// </summary>
    public static IServiceCollection AddExternalIdGraphClient(this IServiceCollection services)
    {
        services.AddScoped<IGraphClient>(sp =>
        {
            var options = sp.GetRequiredService<IOptions<MigrationOptions>>().Value;
            var credManager = sp.GetRequiredService<IEnumerable<ICredentialManager>>()
                .Last(); // External ID credential manager
            var telemetry = sp.GetRequiredService<ITelemetryService>();
            var factoryLogger = sp.GetRequiredService<ILogger<GraphClientFactory>>();
            var clientLogger = sp.GetRequiredService<ILogger<GraphClient>>();
            var retryOptions = Options.Create(options.Retry);

            var factory = new GraphClientFactory(credManager, factoryLogger, telemetry);
            var graphServiceClient = factory.CreateClient(options.ExternalId.Scopes);

            return new GraphClient(graphServiceClient, retryOptions, clientLogger, telemetry);
        });

        return services;
    }
}
