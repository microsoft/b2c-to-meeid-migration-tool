// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
namespace B2CMigrationKit.Core.Models;

/// <summary>
/// Queue message enqueued by <c>worker-migrate</c> and consumed by <c>worker-phone</c>.
///
/// Intentionally contains only identifiers — no phone number.
/// The phone worker fetches the MFA phone from B2C itself
/// (GET /users/{B2CUserId}/authentication/phoneMethods/{mobilePhoneMethodId})
/// so that sensitive phone data never sits in queue messages.
/// </summary>
public class PhoneRegistrationMessage
{
    /// <summary>
    /// The original B2C object ID (GUID). Used by the phone worker to look up
    /// the MFA phone number via GET /authentication/phoneMethods.
    /// </summary>
    public string B2CUserId { get; set; } = string.Empty;

    /// <summary>
    /// The user's UPN in Entra External ID (post-domain-swap).
    /// Used as the target for POST /users/{EEIDUpn}/authentication/phoneMethods.
    /// </summary>
    public string EEIDUpn { get; set; } = string.Empty;

    /// <summary>
    /// Number of times this message has been retried.
    /// </summary>
    public int RetryCount { get; set; } = 0;
}
