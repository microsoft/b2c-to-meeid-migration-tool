// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
using B2CMigrationKit.Core.Models;

namespace B2CMigrationKit.Core.Abstractions;

/// <summary>
/// Provides authentication services for validating credentials during JIT migration.
/// </summary>
public interface IAuthenticationService
{
    /// <summary>
    /// Validates user credentials against Azure AD B2C using ROPC flow.
    /// </summary>
    /// <param name="username">The username (email or UPN).</param>
    /// <param name="password">The user's password.</param>
    /// <param name="cancellationToken">Token to cancel the operation.</param>
    /// <returns>Authentication result indicating success or failure.</returns>
    Task<AuthenticationResult> ValidateCredentialsAsync(
        string username,
        string password,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Validates that a password meets complexity requirements.
    /// </summary>
    /// <param name="password">The password to validate.</param>
    /// <returns>Validation result with any error messages.</returns>
    PasswordValidationResult ValidatePasswordComplexity(string password);
}
