// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
using Azure.Core;

namespace B2CMigrationKit.Core.Abstractions;

/// <summary>
/// Manages multiple Azure AD app registrations for parallel operations to work around rate limits.
/// </summary>
public interface ICredentialManager
{
    /// <summary>
    /// Gets the next available credential in a round-robin fashion.
    /// </summary>
    /// <returns>A token credential for authentication.</returns>
    TokenCredential GetNextCredential();

    /// <summary>
    /// Gets a specific credential by index.
    /// </summary>
    /// <param name="index">The index of the credential to retrieve.</param>
    /// <returns>A token credential for authentication.</returns>
    TokenCredential GetCredential(int index);

    /// <summary>
    /// Gets the total number of available credentials.
    /// </summary>
    int CredentialCount { get; }

    /// <summary>
    /// Reports that a credential encountered throttling.
    /// </summary>
    /// <param name="credentialIndex">The index of the credential that was throttled.</param>
    /// <param name="retryAfterSeconds">The number of seconds to wait before retrying.</param>
    void ReportThrottling(int credentialIndex, int retryAfterSeconds);
}
