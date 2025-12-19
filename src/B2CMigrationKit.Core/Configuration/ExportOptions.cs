// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
namespace B2CMigrationKit.Core.Configuration;

/// <summary>
/// Configuration options for export operations.
/// </summary>
public class ExportOptions
{
    /// <summary>
    /// Gets or sets the fields to select from B2C during export.
    /// Comma-separated list of field names (e.g., "id,userPrincipalName,displayName").
    /// Default includes standard fields + identities.
    /// </summary>
    public string SelectFields { get; set; } = "id,userPrincipalName,displayName,givenName,surname,mail,mobilePhone,identities";

    /// <summary>
    /// Gets or sets the maximum number of users to export.
    /// If null or 0, exports all users. Useful for testing with limited datasets.
    /// </summary>
    public int? MaxUsers { get; set; }

    /// <summary>
    /// Gets or sets a filter pattern for user displayName or userPrincipalName.
    /// If specified, only users whose displayName or userPrincipalName contains this value will be exported.
    /// Case-insensitive. Examples: "MigTest", "contoso", "john.doe"
    /// If null or empty, exports all users (subject to MaxUsers limit).
    /// </summary>
    public string? FilterPattern { get; set; }
}
