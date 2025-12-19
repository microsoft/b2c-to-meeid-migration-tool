// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
namespace B2CMigrationKit.Core.Models;

/// <summary>
/// Represents the result of a credential validation attempt.
/// </summary>
public class AuthenticationResult
{
    /// <summary>
    /// Gets or sets whether authentication was successful.
    /// </summary>
    public bool Success { get; set; }

    /// <summary>
    /// Gets or sets the error code if authentication failed.
    /// </summary>
    public string? ErrorCode { get; set; }

    /// <summary>
    /// Gets or sets the error description if authentication failed.
    /// </summary>
    public string? ErrorDescription { get; set; }

    /// <summary>
    /// Gets or sets the user's object ID if authentication was successful.
    /// </summary>
    public string? UserId { get; set; }

    /// <summary>
    /// Gets or sets whether the account is locked out.
    /// </summary>
    public bool IsLockedOut { get; set; }

    /// <summary>
    /// Gets or sets whether MFA is required.
    /// </summary>
    public bool RequiresMfa { get; set; }

    /// <summary>
    /// Gets or sets additional context from the authentication attempt.
    /// </summary>
    public Dictionary<string, string> Context { get; set; } = new();

    /// <summary>
    /// Creates a successful authentication result.
    /// </summary>
    public static AuthenticationResult CreateSuccess(string userId)
    {
        return new AuthenticationResult
        {
            Success = true,
            UserId = userId
        };
    }

    /// <summary>
    /// Creates a failed authentication result.
    /// </summary>
    public static AuthenticationResult CreateFailure(string errorCode, string errorDescription)
    {
        return new AuthenticationResult
        {
            Success = false,
            ErrorCode = errorCode,
            ErrorDescription = errorDescription
        };
    }
}
