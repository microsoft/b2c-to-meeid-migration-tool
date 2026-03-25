// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
namespace B2CMigrationKit.Core.Configuration;

/// <summary>
/// Configuration options controlling how <c>worker-migrate</c> transforms users
/// before creating them in Entra External ID.
/// </summary>
public class ImportOptions
{
    /// <summary>
    /// Gets or sets attribute name mappings from B2C to External ID.
    /// Key = source attribute name in B2C, Value = target attribute name in External ID.
    /// Example: { "extension_abc123_CustomerId": "extension_xyz789_LegacyId" }
    /// </summary>
    public Dictionary<string, string> AttributeMappings { get; set; } = new();

    /// <summary>
    /// Gets or sets the list of fields to exclude from import.
    /// These fields will not be copied from B2C to External ID.
    /// Example: ["createdDateTime", "lastPasswordChangeDateTime"]
    /// </summary>
    public List<string> ExcludeFields { get; set; } = new();

    /// <summary>
    /// Gets or sets the migration-specific attribute configuration.
    /// </summary>
    public MigrationAttributesOptions MigrationAttributes { get; set; } = new();

    /// <summary>
    /// When true, the worker-migrate phase will not enqueue phone-registration messages.
    /// Use this to run a dry-run or test migration without populating the phone queue.
    /// Default: false.
    /// </summary>
    public bool SkipPhoneRegistration { get; set; } = false;

    /// <summary>
    /// Optional suffix appended to the local part of UPN, email identities, and displayName
    /// when creating users in External ID. Useful for running multiple migration tests
    /// against the same tenant without collisions with previously migrated users.
    /// Example: "-test2" would transform "user@domain.com" → "user-test2@domain.com"
    /// Default: null (no suffix).
    /// </summary>
    public string? UpnSuffix { get; set; }

}

/// <summary>
/// Configuration for migration-specific attributes (B2CObjectId, RequiresMigration).
/// </summary>
public class MigrationAttributesOptions
{
    /// <summary>
    /// Gets or sets whether to store the original B2C ObjectId in External ID.
    /// Default: true.
    /// </summary>
    public bool StoreB2CObjectId { get; set; } = true;

    /// <summary>
    /// Gets or sets the target attribute name for storing B2C ObjectId.
    /// Only used if StoreB2CObjectId is true.
    /// Default: "extension_{ExtensionAppId}_B2CObjectId"
    /// </summary>
    public string? B2CObjectIdTarget { get; set; }

    /// <summary>
    /// Gets or sets whether to set the RequiresMigration flag in External ID.
    /// Default: true.
    /// </summary>
    public bool SetRequireMigration { get; set; } = true;

    /// <summary>
    /// Gets or sets the target attribute name for the RequiresMigration flag.
    /// Only used if SetRequireMigration is true.
    /// Default: "extension_{ExtensionAppId}_RequiresMigration"
    /// </summary>
    public string? RequireMigrationTarget { get; set; }

    /// <summary>
    /// Gets or sets whether to overwrite extension attributes if user already exists.
    /// When true, updates B2CObjectId and migration flag even if user exists.
    /// Useful for testing/re-running imports.
    /// Default: false
    /// </summary>
    public bool OverwriteExtensionAttributes { get; set; } = false;
}


