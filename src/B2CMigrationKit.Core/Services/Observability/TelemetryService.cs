// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
using B2CMigrationKit.Core.Abstractions;
using B2CMigrationKit.Core.Configuration;
using Microsoft.ApplicationInsights;
using Microsoft.ApplicationInsights.DataContracts;
using Microsoft.Extensions.Logging;
using Microsoft.Extensions.Options;
using System.Collections.Concurrent;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace B2CMigrationKit.Core.Services.Observability;

/// <summary>
/// Provides hybrid telemetry and observability services.
/// Supports both console logging (via ILogger) and Application Insights (via TelemetryClient).
/// Configuration controls which outputs are enabled.
/// </summary>
public class TelemetryService : ITelemetryService
{
    private readonly ILogger<TelemetryService> _logger;
    private readonly TelemetryClient? _telemetryClient;
    private readonly TelemetryOptions _options;
    private readonly ConcurrentDictionary<string, long> _counters = new();
    private readonly SemaphoreSlim _fileLock = new(1, 1);
    private readonly ConcurrentBag<Task> _pendingFileTasks = new();
    private static readonly JsonSerializerOptions _jsonOpts = new()
    {
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull
    };

    public TelemetryService(
        ILogger<TelemetryService> logger,
        IOptions<TelemetryOptions> options,
        TelemetryClient? telemetryClient = null)
    {
        _logger = logger ?? throw new ArgumentNullException(nameof(logger));
        _options = options?.Value ?? throw new ArgumentNullException(nameof(options));
        _telemetryClient = telemetryClient;

        // Log telemetry configuration at startup
        if (_options.UseConsoleLogging)
        {
            _logger.LogInformation("Telemetry: Console logging ENABLED");
        }

        if (_options.UseApplicationInsights && _telemetryClient != null)
        {
            _logger.LogInformation("Telemetry: Application Insights ENABLED");
        }
        else if (_options.UseApplicationInsights && _telemetryClient == null)
        {
            _logger.LogWarning("Telemetry: Application Insights requested but TelemetryClient not available");
        }
        if (!string.IsNullOrEmpty(_options.LogFilePath))
        {
            _logger.LogInformation("Telemetry: File output ENABLED → {Path}", _options.LogFilePath);
        }    }

    public void TrackEvent(string eventName, IDictionary<string, string>? properties = null)
    {
        if (!_options.Enabled) return;

        // Console logging
        if (_options.UseConsoleLogging)
        {
            var props = properties != null ? string.Join(", ", properties.Select(p => $"{p.Key}={p.Value}")) : "";
            _logger.LogInformation("[EVENT] {EventName} {Properties}", eventName, props);
        }

        // File logging (tracked for graceful flush on shutdown)
        if (!string.IsNullOrEmpty(_options.LogFilePath))
        {
            _pendingFileTasks.Add(AppendToLogFileAsync("event", eventName, properties));
        }

        // Application Insights
        if (_options.UseApplicationInsights && _telemetryClient != null)
        {
            var eventTelemetry = new EventTelemetry(eventName);
            
            if (properties != null)
            {
                foreach (var prop in properties)
                {
                    eventTelemetry.Properties[prop.Key] = prop.Value;
                }
            }

            // Add global properties
            foreach (var globalProp in _options.GlobalProperties)
            {
                eventTelemetry.Properties[globalProp.Key] = globalProp.Value;
            }

            _telemetryClient.TrackEvent(eventTelemetry);
        }
    }

    public void TrackMetric(string metricName, double value, IDictionary<string, string>? properties = null)
    {
        if (!_options.Enabled) return;

        // Console logging
        if (_options.UseConsoleLogging)
        {
            var props = properties != null ? string.Join(", ", properties.Select(p => $"{p.Key}={p.Value}")) : "";
            _logger.LogInformation("[METRIC] {MetricName}={Value} {Properties}", metricName, value, props);
        }

        // Application Insights
        if (_options.UseApplicationInsights && _telemetryClient != null)
        {
            var metricTelemetry = new MetricTelemetry(metricName, value);
            
            if (properties != null)
            {
                foreach (var prop in properties)
                {
                    metricTelemetry.Properties[prop.Key] = prop.Value;
                }
            }

            _telemetryClient.TrackMetric(metricTelemetry);
        }
    }

    public void TrackException(Exception exception, IDictionary<string, string>? properties = null)
    {
        if (!_options.Enabled || !_options.TrackExceptions) return;

        // Console logging
        if (_options.UseConsoleLogging)
        {
            var props = properties != null ? string.Join(", ", properties.Select(p => $"{p.Key}={p.Value}")) : "";
            _logger.LogError(exception, "[EXCEPTION] {Properties}", props);
        }

        // File logging (tracked for graceful flush on shutdown)
        if (!string.IsNullOrEmpty(_options.LogFilePath))
        {
            var exProps = new Dictionary<string, string>(properties ?? new Dictionary<string, string>())
            {
                ["exceptionType"] = exception.GetType().Name,
                ["message"] = exception.Message
            };
            _pendingFileTasks.Add(AppendToLogFileAsync("exception", exception.GetType().Name, exProps));
        }

        // Application Insights
        if (_options.UseApplicationInsights && _telemetryClient != null)
        {
            var exceptionTelemetry = new ExceptionTelemetry(exception);
            
            if (properties != null)
            {
                foreach (var prop in properties)
                {
                    exceptionTelemetry.Properties[prop.Key] = prop.Value;
                }
            }

            _telemetryClient.TrackException(exceptionTelemetry);
        }
    }

    public void TrackDependency(
        string dependencyType,
        string target,
        string name,
        string? data,
        TimeSpan duration,
        bool success)
    {
        if (!_options.Enabled || !_options.TrackDependencies) return;

        // Console logging
        if (_options.UseConsoleLogging)
        {
            _logger.LogInformation("[DEPENDENCY] {Type} {Target}/{Name} Duration={Duration}ms Success={Success}",
                dependencyType, target, name, duration.TotalMilliseconds, success);
        }

        // Application Insights
        if (_options.UseApplicationInsights && _telemetryClient != null)
        {
            var dependencyTelemetry = new DependencyTelemetry(
                dependencyType,
                target,
                name,
                data,
                DateTimeOffset.UtcNow - duration,
                duration,
                resultCode: success ? "200" : "500",
                success);

            _telemetryClient.TrackDependency(dependencyTelemetry);
        }
    }

    public void IncrementCounter(string counterName, int increment = 1)
    {
        if (!_options.Enabled) return;

        _counters.AddOrUpdate(counterName, increment, (key, current) => current + increment);

        var newValue = _counters[counterName];

        // Console logging (throttled)
        if (_options.UseConsoleLogging && (newValue % 100 == 0 || newValue % 1000 == 0))
        {
            _logger.LogInformation("[COUNTER] {CounterName}={Value}", counterName, newValue);
        }

        // Application Insights (send every increment as metric)
        if (_options.UseApplicationInsights && _telemetryClient != null)
        {
            _telemetryClient.TrackMetric(counterName, newValue);
        }
    }

    public async Task FlushAsync()
    {
        if (!_options.Enabled) return;

        // Console logging - log all final counter values
        if (_options.UseConsoleLogging)
        {
            foreach (var counter in _counters)
            {
                _logger.LogInformation("[COUNTER] {CounterName}={Value}", counter.Key, counter.Value);
            }
        }

        // Application Insights - flush buffer
        if (_options.UseApplicationInsights && _telemetryClient != null)
        {
            _telemetryClient.Flush();
        }

        // Drain any in-flight file writes so no telemetry is lost on shutdown
        if (!string.IsNullOrEmpty(_options.LogFilePath) && !_pendingFileTasks.IsEmpty)
        {
            await Task.WhenAll(_pendingFileTasks).ConfigureAwait(false);
        }
    }

    private async Task AppendToLogFileAsync(string type, string name, IDictionary<string, string>? properties)
    {
        try
        {
            var entry = new Dictionary<string, string?>
            {
                ["ts"]   = DateTimeOffset.UtcNow.ToString("o"),
                ["type"] = type,
                ["name"] = name
            };

            if (properties != null)
            {
                foreach (var kv in properties)
                {
                    entry[kv.Key] = kv.Value;
                }
            }

            var line = JsonSerializer.Serialize(entry, _jsonOpts) + "\n";

            await _fileLock.WaitAsync();
            try
            {
                await File.AppendAllTextAsync(_options.LogFilePath!, line);
            }
            finally
            {
                _fileLock.Release();
            }
        }
        catch
        {
            // File telemetry is best-effort; never block or crash the worker.
        }
    }
}
