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
                "export" => await RunExportAsync(host),
                "import" => await RunImportAsync(host),
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
        System.Console.WriteLine("Starting user export from Azure AD B2C...");
        System.Console.WriteLine();

        var orchestrator = host.Services.GetRequiredService<ExportOrchestrator>();
        var result = await orchestrator.ExecuteAsync();

        if (result.Success)
        {
            System.Console.ForegroundColor = ConsoleColor.Green;
            System.Console.WriteLine();
            System.Console.WriteLine("Export completed successfully!");
            System.Console.WriteLine($"Total users exported: {result.Summary?.TotalItems ?? 0}");
            System.Console.WriteLine($"Duration: {result.Duration}");
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
        System.Console.WriteLine("Starting user import to Entra External ID...");
        System.Console.WriteLine();

        var orchestrator = host.Services.GetRequiredService<ImportOrchestrator>();
        var result = await orchestrator.ExecuteAsync();

        if (result.Success)
        {
            System.Console.ForegroundColor = ConsoleColor.Green;
            System.Console.WriteLine();
            System.Console.WriteLine("Import completed successfully!");
            System.Console.WriteLine($"Total users processed: {result.Summary?.TotalItems ?? 0}");
            System.Console.WriteLine($"Successful: {result.Summary?.SuccessCount ?? 0}");
            System.Console.WriteLine($"Failed: {result.Summary?.FailureCount ?? 0}");
            System.Console.WriteLine($"Duration: {result.Duration}");
            System.Console.ResetColor();
            return result.Summary?.FailureCount > 0 ? 2 : 0;
        }
        else
        {
            System.Console.ForegroundColor = ConsoleColor.Red;
            System.Console.WriteLine();
            System.Console.WriteLine("Import failed!");
            System.Console.WriteLine($"Error: {result.ErrorMessage}");
            System.Console.ResetColor();
            return 1;
        }
    }

    static void ShowHelp()
    {
        System.Console.WriteLine("B2C Migration Kit - Console Runner");
        System.Console.WriteLine("===================================");
        System.Console.WriteLine();
        System.Console.WriteLine("Usage: B2CMigrationKit.Console <operation> [options]");
        System.Console.WriteLine();
        System.Console.WriteLine("Operations:");
        System.Console.WriteLine("  export    Export users from Azure AD B2C to Blob Storage");
        System.Console.WriteLine("  import    Import users from Blob Storage to Entra External ID");
        System.Console.WriteLine("  help      Show this help message");
        System.Console.WriteLine();
        System.Console.WriteLine("Options:");
        System.Console.WriteLine("  --config <path>    Path to configuration file (default: appsettings.json)");
        System.Console.WriteLine("  --verbose          Enable verbose logging");
        System.Console.WriteLine();
        System.Console.WriteLine("Examples:");
        System.Console.WriteLine("  B2CMigrationKit.Console export");
        System.Console.WriteLine("  B2CMigrationKit.Console import --config production.json");
        System.Console.WriteLine("  B2CMigrationKit.Console export --verbose");
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
