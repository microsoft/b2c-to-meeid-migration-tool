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
        services.Configure<KeyVaultOptions>(configuration.GetSection($"{MigrationOptions.SectionName}:KeyVault"));

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
        services.AddSingleton<IQueueClient, QueueStorageClient>();

        // Register audit client based on AuditMode (Table | File | None)
        var auditMode = configuration.GetValue<string>($"{MigrationOptions.SectionName}:Storage:AuditMode") ?? "Table";
        switch (auditMode.Trim().ToLowerInvariant())
        {
            case "file":
                services.AddSingleton<ITableStorageClient, FileAuditClient>();
                break;
            case "none":
                services.AddSingleton<ITableStorageClient, NullAuditClient>();
                break;
            default: // "table"
                services.AddSingleton<ITableStorageClient, TableStorageClient>();
                break;
        }

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

        // Register External ID Credential Manager (skip if disabled — e.g. master/harvest role)
        services.AddSingleton<ICredentialManager>(sp =>
        {
            var options = sp.GetRequiredService<IOptions<MigrationOptions>>().Value;
            var logger = sp.GetRequiredService<ILogger<CredentialManager>>();

            if (!options.ExternalId.AppRegistration.Enabled)
            {
                logger.LogInformation("External ID app registration is disabled — skipping credential setup (master/harvest role).");
                return new NullCredentialManager();
            }

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

        // ExportOrchestrator (Mode A): B2C Graph client + blob storage
        services.AddScoped<ExportOrchestrator>(sp =>
        {
            var options = sp.GetRequiredService<IOptions<MigrationOptions>>().Value;
            var credManagers = sp.GetRequiredService<IEnumerable<ICredentialManager>>();
            var telemetry = sp.GetRequiredService<ITelemetryService>();
            var factoryLogger = sp.GetRequiredService<ILogger<GraphClientFactory>>();
            var clientLogger = sp.GetRequiredService<ILogger<GraphClient>>();
            var retryOptions = sp.GetRequiredService<IOptions<RetryOptions>>();
            var blobClient = sp.GetRequiredService<IBlobStorageClient>();
            var orchestratorLogger = sp.GetRequiredService<ILogger<ExportOrchestrator>>();

            var factory = new GraphClientFactory(credManagers.First(), factoryLogger, telemetry);
            var graphServiceClient = factory.CreateClient(options.B2C.Scopes);
            var graphClient = new GraphClient(graphServiceClient, retryOptions, clientLogger, telemetry, "B2C");

            return new ExportOrchestrator(graphClient, blobClient, telemetry,
                Options.Create(options), orchestratorLogger);
        });

        // ImportOrchestrator (Mode A): EEID Graph client + blob storage
        services.AddScoped<ImportOrchestrator>(sp =>
        {
            var options = sp.GetRequiredService<IOptions<MigrationOptions>>().Value;
            var credManagers = sp.GetRequiredService<IEnumerable<ICredentialManager>>().ToList();
            var telemetry = sp.GetRequiredService<ITelemetryService>();
            var factoryLogger = sp.GetRequiredService<ILogger<GraphClientFactory>>();
            var clientLogger = sp.GetRequiredService<ILogger<GraphClient>>();
            var retryOptions = sp.GetRequiredService<IOptions<RetryOptions>>();
            var blobClient = sp.GetRequiredService<IBlobStorageClient>();
            var orchestratorLogger = sp.GetRequiredService<ILogger<ImportOrchestrator>>();

            var factory = new GraphClientFactory(credManagers.Last(), factoryLogger, telemetry);
            var graphServiceClient = factory.CreateClient(options.ExternalId.Scopes);
            var graphClient = new GraphClient(graphServiceClient, retryOptions, clientLogger, telemetry, "EEID");

            return new ImportOrchestrator(graphClient, blobClient, telemetry,
                Options.Create(options), orchestratorLogger);
        });

        // HarvestOrchestrator (Mode B): uses B2C Graph client + queue
        services.AddScoped<HarvestOrchestrator>(sp =>
        {
            var options = sp.GetRequiredService<IOptions<MigrationOptions>>().Value;
            var credManagers = sp.GetRequiredService<IEnumerable<ICredentialManager>>();
            var telemetry = sp.GetRequiredService<ITelemetryService>();
            var factoryLogger = sp.GetRequiredService<ILogger<GraphClientFactory>>();
            var clientLogger = sp.GetRequiredService<ILogger<GraphClient>>();
            var retryOptions = sp.GetRequiredService<IOptions<RetryOptions>>();
            var queueClient = sp.GetRequiredService<IQueueClient>();
            var orchestratorLogger = sp.GetRequiredService<ILogger<HarvestOrchestrator>>();

            var factory = new GraphClientFactory(credManagers.First(), factoryLogger, telemetry);
            var graphServiceClient = factory.CreateClient(options.B2C.Scopes);
            var graphClient = new GraphClient(graphServiceClient, retryOptions, clientLogger, telemetry, "B2C");

            return new HarvestOrchestrator(graphClient, queueClient, telemetry,
                Options.Create(options), orchestratorLogger);
        });

        // WorkerMigrateOrchestrator: uses B2C Graph client (fetch) + EEID Graph client (create) + queue + table
        services.AddScoped<WorkerMigrateOrchestrator>(sp =>
        {
            var options = sp.GetRequiredService<IOptions<MigrationOptions>>().Value;
            var credManagers = sp.GetRequiredService<IEnumerable<ICredentialManager>>().ToList();
            var telemetry = sp.GetRequiredService<ITelemetryService>();
            var factoryLogger = sp.GetRequiredService<ILogger<GraphClientFactory>>();
            var clientLogger = sp.GetRequiredService<ILogger<GraphClient>>();
            var retryOptions = sp.GetRequiredService<IOptions<RetryOptions>>();
            var queueClient = sp.GetRequiredService<IQueueClient>();
            var tableClient = sp.GetRequiredService<ITableStorageClient>();
            var orchestratorLogger = sp.GetRequiredService<ILogger<WorkerMigrateOrchestrator>>();

            // B2C Graph client (first credential manager)
            var b2cFactory = new GraphClientFactory(credManagers.First(), factoryLogger, telemetry);
            var b2cServiceClient = b2cFactory.CreateClient(options.B2C.Scopes);
            var b2cClient = new GraphClient(b2cServiceClient, retryOptions, clientLogger, telemetry, "B2C");

            // EEID Graph client (second credential manager)
            var eeidFactory = new GraphClientFactory(credManagers.Last(), factoryLogger, telemetry);
            var eeidServiceClient = eeidFactory.CreateClient(options.ExternalId.Scopes);
            var eeidClient = new GraphClient(eeidServiceClient, retryOptions, clientLogger, telemetry, "EEID");

            return new WorkerMigrateOrchestrator(b2cClient, eeidClient, queueClient, tableClient,
                telemetry, Options.Create(options), orchestratorLogger);
        });

        // PhoneRegistrationWorker: B2C (phone lookup) + EEID (register) + queue + table
        services.AddScoped<PhoneRegistrationWorker>(sp =>
        {
            var options = sp.GetRequiredService<IOptions<MigrationOptions>>().Value;
            var credManagers = sp.GetRequiredService<IEnumerable<ICredentialManager>>().ToList();
            var telemetry = sp.GetRequiredService<ITelemetryService>();
            var factoryLogger = sp.GetRequiredService<ILogger<GraphClientFactory>>();
            var clientLogger = sp.GetRequiredService<ILogger<GraphClient>>();
            var retryOptions = sp.GetRequiredService<IOptions<RetryOptions>>();
            var queueClient = sp.GetRequiredService<IQueueClient>();
            var tableClient = sp.GetRequiredService<ITableStorageClient>();
            var workerLogger = sp.GetRequiredService<ILogger<PhoneRegistrationWorker>>();

            // B2C Graph client — for GetMfaPhoneNumberAsync
            var b2cFactory = new GraphClientFactory(credManagers.First(), factoryLogger, telemetry);
            var b2cServiceClient = b2cFactory.CreateClient(options.B2C.Scopes);
            var b2cClient = new GraphClient(b2cServiceClient, retryOptions, clientLogger, telemetry, "B2C");

            // EEID Graph client — for RegisterPhoneAuthMethodAsync
            var eeidFactory = new GraphClientFactory(credManagers.Last(), factoryLogger, telemetry);
            var eeidServiceClient = eeidFactory.CreateClient(options.ExternalId.Scopes);
            var eeidClient = new GraphClient(eeidServiceClient, retryOptions, clientLogger, telemetry, "EEID");

            return new PhoneRegistrationWorker(b2cClient, eeidClient, queueClient, tableClient,
                telemetry, Options.Create(options), workerLogger);
        });

        // ValidateOrchestrator: B2C Graph client + EEID Graph client + queue + blob
        services.AddScoped<ValidateOrchestrator>(sp =>
        {
            var options = sp.GetRequiredService<IOptions<MigrationOptions>>().Value;
            var credManagers = sp.GetRequiredService<IEnumerable<ICredentialManager>>().ToList();
            var telemetry = sp.GetRequiredService<ITelemetryService>();
            var factoryLogger = sp.GetRequiredService<ILogger<GraphClientFactory>>();
            var clientLogger = sp.GetRequiredService<ILogger<GraphClient>>();
            var retryOptions = sp.GetRequiredService<IOptions<RetryOptions>>();
            var queueClient = sp.GetRequiredService<IQueueClient>();
            var blobClient = sp.GetRequiredService<IBlobStorageClient>();
            var orchestratorLogger = sp.GetRequiredService<ILogger<ValidateOrchestrator>>();

            // B2C Graph client (first credential manager)
            var b2cFactory = new GraphClientFactory(credManagers.First(), factoryLogger, telemetry);
            var b2cServiceClient = b2cFactory.CreateClient(options.B2C.Scopes);
            var b2cClient = new GraphClient(b2cServiceClient, retryOptions, clientLogger, telemetry, "B2C");

            // EEID Graph client (second credential manager — null if disabled)
            IGraphClient? eeidClient = null;
            if (options.ExternalId.AppRegistration.Enabled)
            {
                var eeidFactory = new GraphClientFactory(credManagers.Last(), factoryLogger, telemetry);
                var eeidServiceClient = eeidFactory.CreateClient(options.ExternalId.Scopes);
                eeidClient = new GraphClient(eeidServiceClient, retryOptions, clientLogger, telemetry, "EEID");
            }

            return new ValidateOrchestrator(b2cClient, eeidClient, queueClient, blobClient,
                Options.Create(options), orchestratorLogger);
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
            var externalIdGraphClient = new GraphClient(graphServiceClient, retryOptions, clientLogger, telemetry, "EEID");

            return new JitMigrationService(authService, externalIdGraphClient, telemetry, Options.Create(options), logger);
        });

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
