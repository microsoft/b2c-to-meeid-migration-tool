// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
namespace B2CMigrationKit.Core.Configuration;

/// <summary>
/// Configuration options for telemetry and observability.
/// </summary>
public class TelemetryOptions
{
    /// <summary>
    /// Gets or sets the Application Insights connection string.
    /// </summary>
    public string? ConnectionString { get; set; }

    /// <summary>
    /// Gets or sets the Application Insights instrumentation key (legacy).
    /// </summary>
    public string? InstrumentationKey { get; set; }

    /// <summary>
    /// Gets or sets whether telemetry is enabled (default: true).
    /// </summary>
    public bool Enabled { get; set; } = true;

    /// <summary>
    /// Gets or sets whether to use Application Insights SDK for telemetry.
    /// When false, only console logging is used (useful for local development).
    /// Default: false (console only).
    /// </summary>
    public bool UseApplicationInsights { get; set; } = false;

    /// <summary>
    /// Gets or sets whether to enable console logging.
    /// Can be used simultaneously with Application Insights.
    /// Default: true (always log to console).
    /// </summary>
    public bool UseConsoleLogging { get; set; } = true;

    /// <summary>
    /// Gets or sets the sampling rate percentage (default: 100).
    /// </summary>
    public double SamplingPercentage { get; set; } = 100.0;

    /// <summary>
    /// Gets or sets whether to track dependencies (default: true).
    /// </summary>
    public bool TrackDependencies { get; set; } = true;

    /// <summary>
    /// Gets or sets whether to track exceptions (default: true).
    /// </summary>
    public bool TrackExceptions { get; set; } = true;

    /// <summary>
    /// Gets or sets custom properties to include with all telemetry.
    /// </summary>
    public Dictionary<string, string> GlobalProperties { get; set; } = new();
}
