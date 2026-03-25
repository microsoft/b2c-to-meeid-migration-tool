// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
namespace B2CMigrationKit.Core.Models;

/// <summary>
/// Represents a user profile with all relevant identity attributes.
/// </summary>
public class UserProfile
{
    /// <summary>
    /// Gets or sets the user's object ID in Azure AD.
    /// </summary>
    public string? Id { get; set; }

    /// <summary>
    /// Gets or sets the user principal name (UPN).
    /// </summary>
    public string? UserPrincipalName { get; set; }

    /// <summary>
    /// Gets or sets the user's display name.
    /// </summary>
    public string? DisplayName { get; set; }

    /// <summary>
    /// Gets or sets the user's given name (first name).
    /// </summary>
    public string? GivenName { get; set; }

    /// <summary>
    /// Gets or sets the user's surname (last name).
    /// </summary>
    public string? Surname { get; set; }

    /// <summary>
    /// Gets or sets the user's primary email address.
    /// </summary>
    public string? Mail { get; set; }

    /// <summary>
    /// Gets or sets alternative email addresses.
    /// </summary>
    public List<string> OtherMails { get; set; } = new();

    /// <summary>
    /// Gets or sets the user's mobile phone number (contact field on the user object).
    /// This is the standard Graph <c>mobilePhone</c> profile attribute — a contact detail
    /// that B2C users may or may not have set. It is NOT necessarily the MFA phone.
    /// See <see cref="MfaPhoneNumber"/> for the actual registered MFA phone method.
    /// </summary>
    public string? MobilePhone { get; set; }

    /// <summary>
    /// Gets or sets the user's registered MFA mobile phone number, fetched from
    /// <c>GET /users/{id}/authentication/phoneMethods/3179e48a-750b-4051-897c-87b9720928f7</c>
    /// during the <c>phone-harvest</c> phase.
    /// Null if the user has no mobile phone authentication method registered in B2C,
    /// or if the phone-harvest phase has not been run yet.
    /// This value is written to the <c>phones_*.json</c> blobs and merged into
    /// <see cref="UserProfile"/> by <c>ImportOrchestrator</c> at import time.
    /// </summary>
    public string? MfaPhoneNumber { get; set; }

    /// <summary>
    /// Gets or sets the user's street address.
    /// </summary>
    public string? StreetAddress { get; set; }

    /// <summary>
    /// Gets or sets the user's city.
    /// </summary>
    public string? City { get; set; }

    /// <summary>
    /// Gets or sets the user's state or province.
    /// </summary>
    public string? State { get; set; }

    /// <summary>
    /// Gets or sets the user's postal code.
    /// </summary>
    public string? PostalCode { get; set; }

    /// <summary>
    /// Gets or sets the user's country.
    /// </summary>
    public string? Country { get; set; }

    /// <summary>
    /// Gets or sets whether the account is enabled.
    /// </summary>
    public bool AccountEnabled { get; set; } = true;

    /// <summary>
    /// Gets or sets the password profile (used during user creation).
    /// </summary>
    public PasswordProfile? PasswordProfile { get; set; }

    /// <summary>
    /// Gets or sets extension attributes (custom properties).
    /// Key format: extension_{appId}_{attributeName}
    /// </summary>
    public Dictionary<string, object> ExtensionAttributes { get; set; } = new();

    /// <summary>
    /// Gets or sets identities for the user (email, username, etc.).
    /// </summary>
    public List<ObjectIdentity> Identities { get; set; } = new();

    /// <summary>
    /// Gets or sets the creation timestamp.
    /// </summary>
    public DateTimeOffset? CreatedDateTime { get; set; }

    /// <summary>
    /// Gets or sets additional properties not explicitly mapped.
    /// </summary>
    public Dictionary<string, object> AdditionalData { get; set; } = new();
}

/// <summary>
/// Represents a password profile for user creation.
/// </summary>
public class PasswordProfile
{
    /// <summary>
    /// Gets or sets the password.
    /// </summary>
    public string? Password { get; set; }

    /// <summary>
    /// Gets or sets whether to force password change on next sign-in.
    /// </summary>
    public bool ForceChangePasswordNextSignIn { get; set; } = true;
}

/// <summary>
/// Represents an identity associated with a user (email, federated, etc.).
/// </summary>
public class ObjectIdentity
{
    /// <summary>
    /// Gets or sets the sign-in type (e.g., "emailAddress", "userName", "federated").
    /// </summary>
    public string? SignInType { get; set; }

    /// <summary>
    /// Gets or sets the issuer (e.g., tenant domain or external IdP).
    /// </summary>
    public string? Issuer { get; set; }

    /// <summary>
    /// Gets or sets the issuer-assigned ID (the actual identity value).
    /// </summary>
    public string? IssuerAssignedId { get; set; }
}
