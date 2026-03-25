// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
using Azure.Core;
using B2CMigrationKit.Core.Abstractions;

namespace B2CMigrationKit.Core.Services.Infrastructure;

/// <summary>
/// A no-op credential manager used when External ID is disabled (e.g. master/harvest role).
/// Any attempt to obtain a credential throws, since the caller should not be using EEID in this role.
/// </summary>
public class NullCredentialManager : ICredentialManager
{
    public int CredentialCount => 0;

    public TokenCredential GetNextCredential()
        => throw new InvalidOperationException(
            "External ID is disabled for this role. No EEID credential is available.");

    public TokenCredential GetCredential(int index)
        => throw new InvalidOperationException(
            "External ID is disabled for this role. No EEID credential is available.");

    public void ReportThrottling(int credentialIndex, int retryAfterSeconds) { }
}
