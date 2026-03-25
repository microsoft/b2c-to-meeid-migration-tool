// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.

using B2CMigrationKit.Core.Configuration;
using B2CMigrationKit.Core.Extensions;
using B2CMigrationKit.Core.Services.Orchestrators;
using Microsoft.Extensions.Configuration;
using Microsoft.Extensions.DependencyInjection;
using Microsoft.Extensions.Hosting;
using Microsoft.Extensions.Logging;

namespace B2CMigrationKit.Console;

/// <summary>
/// Console application for running B2C migration operations locally.
/// </summary>
class Program
{
    static async Task<int> Main(string[] args)
    {
        try
        {
            // Parse command line arguments
            var operation = args.Length > 0 ? args[0].ToLowerInvariant() : "help";
            var configPath = GetArgument(args, "--config") ?? "appsettings.json";
            var verbose = HasArgument(args, "--verbose");

            if (operation == "help" || operation == "--help" || operation == "-h")
            {
                ShowHelp();
                return 0;
            }

            System.Console.WriteLine("B2C Migration Kit - Console Runner");
            System.Console.WriteLine("===================================");
            System.Console.WriteLine();

            // Build host
            var host = CreateHostBuilder(args, configPath, verbose).Build();

            // Execute operation
            var exitCode = operation switch
            {
                // Mode A: Simple Export/Import (no MFA, no queues)
                "export"               => await RunExportAsync(host),
                "import"               => await RunImportAsync(host),
                // Mode B: Queue-based Workers (full MFA support)
                "harvest"              => await RunHarvestAsync(host),
                "worker-migrate"       => await RunWorkerMigrateAsync(host),
                "phone-registration"   => await RunPhoneRegistrationAsync(host),
                // Utilities
                "validate"             => await RunValidateAsync(host),
                _ => ShowError($"Unknown operation: {operation}")
            };

            return exitCode;
        }
        catch (Exception ex)
        {
            System.Console.ForegroundColor = ConsoleColor.Red;
            System.Console.WriteLine($"Fatal error: {ex.Message}");
            System.Console.WriteLine(ex.StackTrace);
            System.Console.ResetColor();
            return 1;
        }
    }

    static IHostBuilder CreateHostBuilder(string[] args, string configPath, bool verbose)
    {
        return Host.CreateDefaultBuilder(args)
            .ConfigureAppConfiguration((context, config) =>
            {
                config.Sources.Clear();
                config.AddJsonFile(configPath, optional: false, reloadOnChange: false);
                config.AddJsonFile($"appsettings.{context.HostingEnvironment.EnvironmentName}.json",
                    optional: true);
                config.AddEnvironmentVariables();
                config.AddCommandLine(args);
            })
            .ConfigureServices((context, services) =>
            {
                // Register core services
                services.AddMigrationKitCore(context.Configuration);
            })
            .ConfigureLogging((context, logging) =>
            {
                logging.ClearProviders();
                logging.AddConsole(options =>
                {
                    options.TimestampFormat = "HH:mm:ss ";
                });

                if (verbose)
                {
                    logging.SetMinimumLevel(LogLevel.Debug);
                }
                else
                {
                    logging.SetMinimumLevel(LogLevel.Information);
                }
            });
    }

    static async Task<int> RunExportAsync(IHost host)
    {
        System.Console.WriteLine("Starting export phase (Mode A: Simple)...");
        System.Console.WriteLine("Fetching all users from Azure AD B2C and exporting to Blob Storage.");
        System.Console.WriteLine();

        var orchestrator = host.Services.GetRequiredService<ExportOrchestrator>();
        var result = await orchestrator.ExecuteAsync();

        if (result.Success)
        {
            System.Console.ForegroundColor = ConsoleColor.Green;
            System.Console.WriteLine();
            System.Console.WriteLine("Export completed successfully!");
            System.Console.WriteLine($"Total users exported: {result.Summary?.TotalItems ?? 0:N0}");
            System.Console.WriteLine($"Duration            : {result.Duration}");
            System.Console.WriteLine();
            System.Console.WriteLine("Next step:");
            System.Console.WriteLine("  B2CMigrationKit.Console import --config appsettings.json");
            System.Console.ResetColor();
            return 0;
        }
        else
        {
            System.Console.ForegroundColor = ConsoleColor.Red;
            System.Console.WriteLine();
            System.Console.WriteLine("Export failed!");
            System.Console.WriteLine($"Error: {result.ErrorMessage}");
            System.Console.ResetColor();
            return 1;
        }
    }

    static async Task<int> RunImportAsync(IHost host)
    {
        System.Console.WriteLine("Starting import phase (Mode A: Simple)...");
        System.Console.WriteLine("Reading exported users from Blob Storage and creating accounts in Entra External ID.");
        System.Console.WriteLine();

        var orchestrator = host.Services.GetRequiredService<ImportOrchestrator>();
        var result = await orchestrator.ExecuteAsync();

        if (result.Success)
        {
            System.Console.ForegroundColor = ConsoleColor.Green;
            System.Console.WriteLine();
            System.Console.WriteLine("Import completed successfully!");
            System.Console.WriteLine($"Total users processed: {result.Summary?.TotalItems ?? 0:N0}");
            System.Console.WriteLine($"Users created        : {result.Summary?.SuccessCount ?? 0:N0}");
            System.Console.WriteLine($"Duplicates skipped   : {result.Summary?.SkippedCount ?? 0:N0}");
            System.Console.WriteLine($"Failed               : {result.Summary?.FailureCount ?? 0:N0}");
            System.Console.WriteLine($"Duration             : {result.Duration}");
            System.Console.ResetColor();
            return 0;
        }
        else
        {
            System.Console.ForegroundColor = ConsoleColor.Red;
            System.Console.WriteLine();
            System.Console.WriteLine("Import finished with errors!");
            System.Console.WriteLine($"Processed: {result.Summary?.TotalItems ?? 0:N0}");
            System.Console.WriteLine($"Created  : {result.Summary?.SuccessCount ?? 0:N0}");
            System.Console.WriteLine($"Failed   : {result.Summary?.FailureCount ?? 0}");
            System.Console.WriteLine($"Error    : {result.ErrorMessage}");
            System.Console.ResetColor();
            return 1;
        }
    }

    static async Task<int> RunWorkerMigrateAsync(IHost host)
    {
        System.Console.WriteLine("Starting worker-migrate phase...");
        System.Console.WriteLine("Dequeuing user-ID batches from B2C, creating accounts in Entra External ID,");
        System.Console.WriteLine("and enqueuing phone-registration tasks.");
        System.Console.WriteLine();

        var orchestrator = host.Services.GetRequiredService<WorkerMigrateOrchestrator>();
        var result = await orchestrator.ExecuteAsync();

        if (result.Success)
        {
            System.Console.ForegroundColor = ConsoleColor.Green;
            System.Console.WriteLine();
            System.Console.WriteLine("Worker migrate completed successfully!");
            System.Console.WriteLine($"Total users processed  : {result.Summary?.TotalItems ?? 0:N0}");
            System.Console.WriteLine($"Users created          : {result.Summary?.SuccessCount ?? 0:N0}");
            System.Console.WriteLine($"Duplicates             : {result.Summary?.SkippedCount ?? 0:N0}");
            System.Console.WriteLine($"Failed                 : {result.Summary?.FailureCount ?? 0:N0}");
            System.Console.WriteLine($"Duration               : {result.Duration}");
            System.Console.ResetColor();
            return 0;
        }
        else
        {
            System.Console.ForegroundColor = ConsoleColor.Red;
            System.Console.WriteLine();
            System.Console.WriteLine("Worker migrate finished with errors!");
            System.Console.WriteLine($"Total processed  : {result.Summary?.TotalItems ?? 0:N0}");
            System.Console.WriteLine($"Created          : {result.Summary?.SuccessCount ?? 0:N0}");
            System.Console.WriteLine($"Failed           : {result.Summary?.FailureCount ?? 0}");
            System.Console.WriteLine($"Error            : {result.ErrorMessage}");
            System.Console.ResetColor();
            return 1;
        }
    }

    static async Task<int> RunPhoneRegistrationAsync(IHost host)
    {
        System.Console.WriteLine("Starting phone-registration worker...");
        System.Console.WriteLine("Dequeuing phone-registration tasks and registering MFA phone numbers in Entra External ID.");
        System.Console.WriteLine();

        var orchestrator = host.Services.GetRequiredService<PhoneRegistrationWorker>();
        var result = await orchestrator.ExecuteAsync();

        if (result.Success)
        {
            System.Console.ForegroundColor = ConsoleColor.Green;
            System.Console.WriteLine();
            System.Console.WriteLine("Phone registration completed successfully!");
            System.Console.WriteLine($"Total registered: {result.Summary?.SuccessCount ?? 0:N0}");
            System.Console.WriteLine($"Duration: {result.Duration}");
            System.Console.ResetColor();
            return 0;
        }
        else
        {
            System.Console.ForegroundColor = ConsoleColor.Red;
            System.Console.WriteLine();
            System.Console.WriteLine("Phone registration finished with errors!");
            System.Console.WriteLine($"Registered: {result.Summary?.SuccessCount ?? 0:N0}");
            System.Console.WriteLine($"Failed: {result.Summary?.FailureCount ?? 0}");
            System.Console.WriteLine($"Error: {result.ErrorMessage}");
            System.Console.ResetColor();
            return result.Summary?.FailureCount > 0 ? 2 : 1;
        }
    }

    static async Task<int> RunHarvestAsync(IHost host)
    {
        System.Console.WriteLine("Starting Master/Producer harvest phase...");
        System.Console.WriteLine("Fetching all user IDs from Azure AD B2C and enqueuing batches.");
        System.Console.WriteLine();

        var orchestrator = host.Services.GetRequiredService<HarvestOrchestrator>();
        var result = await orchestrator.ExecuteAsync();

        if (result.Success)
        {
            System.Console.ForegroundColor = ConsoleColor.Green;
            System.Console.WriteLine();
            System.Console.WriteLine("Harvest completed successfully!");
            System.Console.WriteLine($"Total IDs enqueued: {result.Summary?.TotalItems ?? 0:N0}");
            System.Console.WriteLine($"Duration: {result.Duration}");
            System.Console.WriteLine();
            System.Console.WriteLine("Next steps (run in parallel, each with its own --config):");
            System.Console.WriteLine("  B2CMigrationKit.Console worker-migrate --config appsettings.worker1.json");
            System.Console.WriteLine("  B2CMigrationKit.Console phone-registration --config appsettings.worker1.json");
            System.Console.ResetColor();
            return 0;
        }
        else
        {
            System.Console.ForegroundColor = ConsoleColor.Red;
            System.Console.WriteLine();
            System.Console.WriteLine("Harvest failed!");
            System.Console.WriteLine($"Error: {result.ErrorMessage}");
            System.Console.ResetColor();
            return 1;
        }
    }

    static async Task<int> RunValidateAsync(IHost host)
    {
        System.Console.WriteLine("Validating connectivity to all external dependencies...");
        System.Console.WriteLine();

        var orchestrator = host.Services.GetRequiredService<ValidateOrchestrator>();
        var result = await orchestrator.ExecuteAsync();

        return result.Success ? 0 : 1;
    }

    static void ShowHelp()
    {
        System.Console.WriteLine("B2C Migration Kit - Console Runner");
        System.Console.WriteLine("===================================");
        System.Console.WriteLine();
        System.Console.WriteLine("Usage: B2CMigrationKit.Console <operation> [options]");
        System.Console.WriteLine();
        System.Console.WriteLine("Operations:");
        System.Console.WriteLine();
        System.Console.WriteLine("  Mode A — Simple Export/Import (no MFA, no queues):");
        System.Console.WriteLine("    export              Export all B2C users to Blob Storage JSON files");
        System.Console.WriteLine("    import              Import users from Blob Storage into Entra External ID");
        System.Console.WriteLine();
        System.Console.WriteLine("  Mode B — Queue-based Workers (full MFA phone migration):");
        System.Console.WriteLine("    harvest             Fetch all user IDs from B2C and enqueue batches");
        System.Console.WriteLine("    worker-migrate      Dequeue batches, create users in EEID, enqueue phone tasks");
        System.Console.WriteLine("    phone-registration  Dequeue phone tasks, register MFA phones in EEID");
        System.Console.WriteLine();
        System.Console.WriteLine("  Utilities:");
        System.Console.WriteLine("    validate            Check connectivity to B2C, EEID, and Azure Storage");
        System.Console.WriteLine();
        System.Console.WriteLine("  help                  Show this help message");
        System.Console.WriteLine();
        System.Console.WriteLine("Options:");
        System.Console.WriteLine("  --config <path>    Path to configuration file (default: appsettings.json)");
        System.Console.WriteLine("  --verbose          Enable verbose logging");
        System.Console.WriteLine();
        System.Console.WriteLine("--- Mode A: Simple Export/Import ---");
        System.Console.WriteLine("Best for: <50K users, no MFA phones to migrate, simpler infrastructure.");
        System.Console.WriteLine();
        System.Console.WriteLine("  Step 1: B2CMigrationKit.Console export --config appsettings.json");
        System.Console.WriteLine("  Step 2: B2CMigrationKit.Console import --config appsettings.json");
        System.Console.WriteLine();
        System.Console.WriteLine("--- Mode B: Queue-based Workers ---");
        System.Console.WriteLine("Best for: large tenants, MFA phone migration needed, parallel scaling.");
        System.Console.WriteLine();
        System.Console.WriteLine("  Step 1 – one instance runs 'harvest' to enqueue all user IDs:");
        System.Console.WriteLine("    B2CMigrationKit.Console harvest --config appsettings.master.json");
        System.Console.WriteLine();
        System.Console.WriteLine("  Step 2a – N workers run 'worker-migrate' in parallel:");
        System.Console.WriteLine("    B2CMigrationKit.Console worker-migrate --config appsettings.worker1.json");
        System.Console.WriteLine("    B2CMigrationKit.Console worker-migrate --config appsettings.worker2.json");
        System.Console.WriteLine();
        System.Console.WriteLine("  Step 2b – (run simultaneously with 2a) M workers run 'phone-registration':");
        System.Console.WriteLine("    B2CMigrationKit.Console phone-registration --config appsettings.worker1.json");
        System.Console.WriteLine("    B2CMigrationKit.Console phone-registration --config appsettings.worker2.json");
    }

    static int ShowError(string message)
    {
        System.Console.ForegroundColor = ConsoleColor.Red;
        System.Console.WriteLine($"Error: {message}");
        System.Console.ResetColor();
        System.Console.WriteLine();
        ShowHelp();
        return 1;
    }

    static string? GetArgument(string[] args, string name)
    {
        for (int i = 0; i < args.Length - 1; i++)
        {
            if (args[i].Equals(name, StringComparison.OrdinalIgnoreCase))
            {
                return args[i + 1];
            }
        }
        return null;
    }

    static bool HasArgument(string[] args, string name)
    {
        return args.Any(a => a.Equals(name, StringComparison.OrdinalIgnoreCase));
    }
}
