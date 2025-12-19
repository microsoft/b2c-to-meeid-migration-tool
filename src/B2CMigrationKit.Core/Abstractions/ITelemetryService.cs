// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
namespace B2CMigrationKit.Core.Abstractions;

/// <summary>
/// Provides telemetry and observability services for the migration toolkit.
/// </summary>
public interface ITelemetryService
{
    /// <summary>
    /// Tracks a custom event.
    /// </summary>
    /// <param name="eventName">The name of the event.</param>
    /// <param name="properties">Optional properties associated with the event.</param>
    void TrackEvent(string eventName, IDictionary<string, string>? properties = null);

    /// <summary>
    /// Tracks a metric value.
    /// </summary>
    /// <param name="metricName">The name of the metric.</param>
    /// <param name="value">The metric value.</param>
    /// <param name="properties">Optional properties associated with the metric.</param>
    void TrackMetric(string metricName, double value, IDictionary<string, string>? properties = null);

    /// <summary>
    /// Tracks an exception.
    /// </summary>
    /// <param name="exception">The exception to track.</param>
    /// <param name="properties">Optional properties associated with the exception.</param>
    void TrackException(Exception exception, IDictionary<string, string>? properties = null);

    /// <summary>
    /// Tracks a dependency call (e.g., to Microsoft Graph or Azure Storage).
    /// </summary>
    /// <param name="dependencyType">The type of dependency (e.g., "HTTP", "Azure Blob").</param>
    /// <param name="target">The target of the dependency call.</param>
    /// <param name="name">The name of the operation.</param>
    /// <param name="data">Optional data about the call.</param>
    /// <param name="duration">The duration of the call.</param>
    /// <param name="success">Whether the call was successful.</param>
    void TrackDependency(
        string dependencyType,
        string target,
        string name,
        string? data,
        TimeSpan duration,
        bool success);

    /// <summary>
    /// Increments a counter metric.
    /// </summary>
    /// <param name="counterName">The name of the counter.</param>
    /// <param name="increment">The amount to increment by (default 1).</param>
    void IncrementCounter(string counterName, int increment = 1);

    /// <summary>
    /// Flushes all telemetry data to ensure it's sent.
    /// </summary>
    Task FlushAsync();
}
