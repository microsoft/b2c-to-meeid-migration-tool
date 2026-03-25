// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
namespace B2CMigrationKit.Core.Models;

/// <summary>
/// A single result from the phone-harvest phase.
/// Serialized as an element of <c>phones_{prefix}{counter}.json</c> blobs written
/// by <see cref="B2CMigrationKit.Core.Services.Orchestrators.PhoneHarvestOrchestrator"/>.
///
/// At import time, <c>ImportOrchestrator</c> loads all <c>phones_*.json</c> blobs into an
/// in-memory dictionary keyed by <see cref="UserId"/> and uses it to set
/// <see cref="UserProfile.MfaPhoneNumber"/> before creating each user in Entra External ID.
/// </summary>
/// <param name="UserId">The B2C user object ID.</param>
/// <param name="PhoneNumber">
/// The MFA mobile phone number in the format returned by Graph
/// (e.g., <c>+1 2065551234</c>), fetched from
/// <c>GET /users/{id}/authentication/phoneMethods/3179e48a-750b-4051-897c-87b9720928f7</c>.
/// </param>
public record PhoneLookupEntry(string UserId, string PhoneNumber);
