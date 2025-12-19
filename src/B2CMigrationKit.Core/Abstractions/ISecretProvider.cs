// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
namespace B2CMigrationKit.Core.Abstractions;

/// <summary>
/// Provides access to secrets stored in Azure Key Vault.
/// </summary>
public interface ISecretProvider
{
    /// <summary>
    /// Gets a secret value by name.
    /// </summary>
    /// <param name="secretName">The name of the secret.</param>
    /// <param name="cancellationToken">Token to cancel the operation.</param>
    /// <returns>The secret value.</returns>
    Task<string> GetSecretAsync(
        string secretName,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Sets a secret value.
    /// </summary>
    /// <param name="secretName">The name of the secret.</param>
    /// <param name="secretValue">The value to store.</param>
    /// <param name="cancellationToken">Token to cancel the operation.</param>
    Task SetSecretAsync(
        string secretName,
        string secretValue,
        CancellationToken cancellationToken = default);
}
