// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
using B2CMigrationKit.Core.Models;

namespace B2CMigrationKit.Core.Abstractions;

/// <summary>
/// Provides access to Microsoft Graph API operations with built-in retry and throttling handling.
/// </summary>
public interface IGraphClient
{
    /// <summary>
    /// Gets users from the directory with paging support.
    /// </summary>
    /// <param name="pageSize">Number of users to retrieve per page.</param>
    /// <param name="select">Optional comma-separated list of properties to select.</param>
    /// <param name="filter">Optional OData filter expression.</param>
    /// <param name="skipToken">Optional skip token for pagination.</param>
    /// <param name="cancellationToken">Token to cancel the operation.</param>
    /// <returns>A page of user profiles with a continuation token.</returns>
    Task<PagedResult<UserProfile>> GetUsersAsync(
        int pageSize = 100,
        string? select = null,
        string? filter = null,
        string? skipToken = null,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Creates a new user in the directory.
    /// </summary>
    /// <param name="user">The user profile to create.</param>
    /// <param name="cancellationToken">Token to cancel the operation.</param>
    /// <returns>The created user profile with assigned ID.</returns>
    Task<UserProfile> CreateUserAsync(
        UserProfile user,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Creates multiple users in a batch operation.
    /// </summary>
    /// <param name="users">The collection of users to create.</param>
    /// <param name="cancellationToken">Token to cancel the operation.</param>
    /// <returns>Results of the batch operation.</returns>
    Task<BatchResult> CreateUsersBatchAsync(
        IEnumerable<UserProfile> users,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Updates an existing user in the directory.
    /// </summary>
    /// <param name="userId">The ID of the user to update.</param>
    /// <param name="updates">Dictionary of property names and values to update.</param>
    /// <param name="cancellationToken">Token to cancel the operation.</param>
    Task UpdateUserAsync(
        string userId,
        Dictionary<string, object> updates,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Gets a user by their object ID.
    /// </summary>
    /// <param name="userId">The user's object ID.</param>
    /// <param name="select">Optional comma-separated list of properties to select.</param>
    /// <param name="cancellationToken">Token to cancel the operation.</param>
    /// <returns>The user profile or null if not found.</returns>
    Task<UserProfile?> GetUserByIdAsync(
        string userId,
        string? select = null,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Searches for a user by extension attribute value.
    /// </summary>
    /// <param name="extensionAttributeName">The name of the extension attribute.</param>
    /// <param name="value">The value to search for.</param>
    /// <param name="cancellationToken">Token to cancel the operation.</param>
    /// <returns>The matching user profile or null if not found.</returns>
    Task<UserProfile?> FindUserByExtensionAttributeAsync(
        string extensionAttributeName,
        string value,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Sets a user's password.
    /// </summary>
    /// <param name="userId">The user's object ID.</param>
    /// <param name="password">The new password.</param>
    /// <param name="forceChangePasswordNextSignIn">Whether to force password change on next sign-in.</param>
    /// <param name="cancellationToken">Token to cancel the operation.</param>
    Task SetUserPasswordAsync(
        string userId,
        string password,
        bool forceChangePasswordNextSignIn = false,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Registers a phone number as a mobile MFA authentication method for the specified user.
    /// Idempotent: a 409 Conflict (phone already registered) is treated as success.
    /// Requires UserAuthenticationMethod.ReadWrite.All on the target tenant.
    /// </summary>
    /// <param name="userIdOrUpn">The user's object ID or userPrincipalName.</param>
    /// <param name="phoneNumber">Phone number in E.164-ish format: "+1 2065551234".</param>
    /// <param name="cancellationToken">Token to cancel the operation.</param>
    Task RegisterPhoneAuthMethodAsync(
        string userIdOrUpn,
        string phoneNumber,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Fetches the full profile for a batch of up to 20 users using the Graph $batch API.
    /// Used by the Worker/Consumer phase of the Master-Worker export pattern to avoid
    /// full-tenant pagination: each worker only resolves its own slice of pre-harvested IDs.
    /// </summary>
    /// <param name="userIds">Up to 20 user object IDs to fetch.</param>
    /// <param name="select">Optional comma-separated list of properties to select.</param>
    /// <param name="cancellationToken">Token to cancel the operation.</param>
    /// <returns>
    /// A list of successfully retrieved user profiles.
    /// Users that were not found or returned an error are omitted (logged at Warning level).
    /// </returns>
    Task<IReadOnlyList<UserProfile>> GetUsersByIdsAsync(
        IEnumerable<string> userIds,
        string? select = null,
        CancellationToken cancellationToken = default);

    /// <summary>
    /// Fetches the registered mobile MFA phone number for a single user from B2C.
    /// Calls <c>GET /users/{userId}/authentication/phoneMethods/3179e48a-750b-4051-897c-87b9720928f7</c>.
    ///
    /// This endpoint belongs to the <c>authenticationMethod</c> Graph resource family,
    /// which has a different throttle budget than the main Users API.
    /// Call throttling is managed by the caller via <see cref="PhoneRegistrationOptions.ThrottleDelayMs"/>.
    ///
    /// Requires <c>UserAuthenticationMethod.Read.All</c> on the B2C tenant.
    /// </summary>
    /// <param name="userId">The user's B2C object ID.</param>
    /// <param name="cancellationToken">Token to cancel the operation.</param>
    /// <returns>
    /// The phone number string (e.g. "+1 2065551234") if the user has a registered
    /// mobile phone authentication method; <c>null</c> if the user has no such method
    /// (HTTP 404) or if the method entry has no phone number set.
    /// </returns>
    Task<string?> GetMfaPhoneNumberAsync(
        string userId,
        CancellationToken cancellationToken = default);
}
