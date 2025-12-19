// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
namespace B2CMigrationKit.Core.Abstractions;

/// <summary>
/// Represents an orchestrator for executing migration operations.
/// </summary>
/// <typeparam name="TResult">The type of result returned by the orchestration.</typeparam>
public interface IOrchestrator<TResult>
{
    /// <summary>
    /// Executes the orchestration asynchronously.
    /// </summary>
    /// <param name="cancellationToken">Token to cancel the operation.</param>
    /// <returns>The result of the orchestration.</returns>
    Task<TResult> ExecuteAsync(CancellationToken cancellationToken = default);
}
