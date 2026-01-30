// Copyright (c) Microsoft Corporation.
// Licensed under the MIT License.
namespace B2CMigrationKit.Core.Models;

/// <summary>
/// Represents the migration status of a user.
/// </summary>
public enum MigrationStatus
{
    /// <summary>
    /// User has not been migrated yet.
    /// </summary>
    NotMigrated = 0,

    /// <summary>
    /// User profile has been imported but password not yet migrated.
    /// </summary>
    ProfileImported = 1,

    /// <summary>
    /// User has been fully migrated including password via JIT.
    /// </summary>
    FullyMigrated = 2,

    /// <summary>
    /// Migration failed for this user.
    /// </summary>
    Failed = 3,

    /// <summary>
    /// User is being migrated (in progress).
    /// </summary>
    InProgress = 4
}

/// <summary>
/// Extension attribute names used for migration tracking.
/// </summary>
public static class MigrationExtensionAttributes
{
    /// <summary>
    /// Extension attribute name for storing the original B2C object ID.
    /// Format: extension_{appId}_B2CObjectId
    /// </summary>
    public const string B2CObjectId = "B2CObjectId";

    /// <summary>
    /// Extension attribute name for indicating if user requires JIT migration.
    /// Format: extension_{appId}_RequiresMigration
    /// Note: The semantic meaning is configurable in JitAuthenticationOptions.MigrationAttributeName
    /// Default behavior: true = requires migration, false = already migrated
    /// </summary>
    public const string RequiresMigration = "RequiresMigration";

    /// <summary>
    /// Extension attribute name for storing migration timestamp.
    /// Format: extension_{appId}_MigrationDate
    /// </summary>
    public const string MigrationDate = "MigrationDate";

    /// <summary>
    /// Gets the full extension attribute name with app ID.
    /// </summary>
    /// <param name="appId">The application ID (without hyphens).</param>
    /// <param name="attributeName">The attribute name.</param>
    /// <returns>The full extension attribute name.</returns>
    public static string GetFullAttributeName(string appId, string attributeName)
    {
        var cleanAppId = appId.Replace("-", string.Empty);
        return $"extension_{cleanAppId}_{attributeName}";
    }
}
