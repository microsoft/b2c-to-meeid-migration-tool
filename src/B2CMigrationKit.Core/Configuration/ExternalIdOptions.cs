// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
using System.ComponentModel.DataAnnotations;

namespace B2CMigrationKit.Core.Configuration;

/// <summary>
/// Configuration options for Microsoft Entra External ID.
/// </summary>
public class ExternalIdOptions
{
    /// <summary>
    /// Gets or sets the External ID tenant ID.
    /// </summary>
    [Required]
    public string TenantId { get; set; } = string.Empty;

    /// <summary>
    /// Gets or sets the External ID tenant domain (e.g., contoso.onmicrosoft.com).
    /// </summary>
    [Required]
    public string TenantDomain { get; set; } = string.Empty;

    /// <summary>
    /// Gets or sets the app registration for External ID access.
    /// </summary>
    [Required]
    public AppRegistration AppRegistration { get; set; } = new();

    /// <summary>
    /// Gets or sets the extension application ID for custom attributes.
    /// This is the app ID (without hyphens) used for extension attributes.
    /// </summary>
    [Required]
    public string ExtensionAppId { get; set; } = string.Empty;

    /// <summary>
    /// Gets or sets custom Graph API scopes (default: https://graph.microsoft.com/.default).
    /// </summary>
    public string[] Scopes { get; set; } = new[] { "https://graph.microsoft.com/.default" };
}
