// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
using System.ComponentModel.DataAnnotations;

namespace B2CMigrationKit.Core.Configuration;

/// <summary>
/// Configuration options for Azure AD B2C.
/// </summary>
public class B2COptions
{
    /// <summary>
    /// Gets or sets the B2C tenant ID (GUID format).
    /// Used for direct Entra ID authentication.
    /// </summary>
    [Required]
    public string TenantId { get; set; } = string.Empty;

    /// <summary>
    /// Gets or sets the B2C tenant domain (e.g., contoso.onmicrosoft.com).
    /// </summary>
    [Required]
    public string TenantDomain { get; set; } = string.Empty;

    /// <summary>
    /// Gets or sets the app registration for B2C access.
    /// For JIT authentication, this app must have:
    /// - Directory.Read.All permission with admin consent
    /// - Client secret configured
    /// - Public client flows enabled
    /// </summary>
    [Required]
    public AppRegistration AppRegistration { get; set; } = new();

    /// <summary>
    /// Gets or sets the ROPC policy name for B2C policy-based authentication (legacy).
    /// NOTE: For JIT migration, we authenticate directly to Entra ID, not via B2C policies.
    /// This property is kept for backward compatibility but is not used in JIT flow.
    /// </summary>
    [Obsolete("JIT authentication now uses direct Entra ID ROPC instead of B2C policies")]
    public string? RopcPolicyName { get; set; }

    /// <summary>
    /// Gets or sets custom Graph API scopes (default: https://graph.microsoft.com/.default).
    /// </summary>
    public string[] Scopes { get; set; } = new[] { "https://graph.microsoft.com/.default" };
}

/// <summary>
/// Represents an Azure AD app registration.
/// </summary>
public class AppRegistration
{
    /// <summary>
    /// Gets or sets the application (client) ID.
    /// </summary>
    [Required]
    public string ClientId { get; set; } = string.Empty;

    /// <summary>
    /// Gets or sets the client secret name (reference to Key Vault or direct value).
    /// </summary>
    public string? ClientSecretName { get; set; }

    /// <summary>
    /// Gets or sets the client secret value (not recommended for production - use Key Vault).
    /// REQUIRED for JIT authentication via Entra ID ROPC flow.
    /// </summary>
    public string? ClientSecret { get; set; }

    /// <summary>
    /// Gets or sets the certificate thumbprint for certificate-based auth.
    /// </summary>
    public string? CertificateThumbprint { get; set; }

    /// <summary>
    /// Gets or sets a friendly name for this app registration.
    /// </summary>
    public string? Name { get; set; }

    /// <summary>
    /// Gets or sets whether this app registration is enabled.
    /// </summary>
    public bool Enabled { get; set; } = true;
}
