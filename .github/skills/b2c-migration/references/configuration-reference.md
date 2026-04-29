# Configuration Reference

Complete JSON schema and settings for the B2C Migration Kit.

## Root Structure

```json
{
  "Migration": {
    "B2C": { ... },
    "ExternalId": { ... },
    "Export": { ... },
    "Import": { ... },
    "Harvest": { ... },
    "PhoneRegistration": { ... },
    "Storage": { ... },
    "Telemetry": { ... },
    "Retry": { ... },
    "MaxConcurrency": 8
  }
}
```

## B2C Configuration

```json
"B2C": {
  "TenantId": "your-b2c-tenant-id",
  "TenantDomain": "yourtenant.onmicrosoft.com",
  "AppRegistration": {
    "ClientId": "app-id-1",
    "ClientSecretName": "B2CAppSecret1",
    "ClientSecret": "actual-secret-for-local-dev",
    "Name": "B2C App 1",
    "Enabled": true
  },
  "Scopes": [ "https://graph.microsoft.com/.default" ]
}
```

Config patterns:
- **Local development** → use `ClientSecret` with the actual secret value
- **Production (Key Vault)** → use `ClientSecretName` with the Key Vault secret name

## External ID Configuration

```json
"ExternalId": {
  "TenantId": "your-external-id-tenant-id",
  "TenantDomain": "yourtenant.onmicrosoft.com",
  "ExtensionAppId": "00000000000000000000000000000000",
  "AppRegistration": {
    "ClientId": "app-id-1",
    "ClientSecretName": "ExternalIdAppSecret1",
    "ClientSecret": "actual-secret-for-local-dev",
    "Name": "External ID App 1",
    "Enabled": true
  }
}
```

`ExtensionAppId` = Application ID of the `b2c-extensions-app`, without hyphens (32 hex characters).

## Export Configuration (Simple Mode)

```json
"Export": {
  "SelectFields": "id,userPrincipalName,displayName,givenName,surname,mail,mobilePhone,identities",
  "MaxUsers": 0,
  "FilterPattern": ""
}
```

| Setting | Default | Notes |
|---------|---------|-------|
| `SelectFields` | *(all standard)* | Comma-separated Graph `$select` fields. Include custom extension attributes. |
| `MaxUsers` | 0 (unlimited) | Cap for smoke tests (e.g., `20`). `0` = export all. |
| `FilterPattern` | *(empty)* | OData `$filter` expression to subset users. |

## Import Configuration (Simple Mode)

```json
"Import": {
  "AttributeMappings": {
    "extension_b2c_LegacyId": "extension_extid_CustomerId"
  },
  "ExcludeFields": ["createdDateTime", "lastPasswordChangeDateTime"],
  "MigrationAttributes": {
    "StoreB2CObjectId": true,
    "B2CObjectIdTarget": "extension_xyz_OriginalB2CId",
    "SetRequireMigration": true,
    "RequireMigrationTarget": "extension_xyz_RequiresMigration",
    "OverwriteExtensionAttributes": false
  },
  "SkipPhoneRegistration": true
}
```

| Setting | Default | Notes |
|---------|---------|-------|
| `AttributeMappings` | `{}` | Rename custom extensions: `"b2c_attr": "eeid_attr"` |
| `ExcludeFields` | `[]` | Attributes to drop during import |
| `StoreB2CObjectId` | `true` | Saves original B2C objectId as extension attribute |
| `SetRequireMigration` | `true` | Marks users for JIT password migration |
| `OverwriteExtensionAttributes` | `false` | If `true`, overwrites existing extension values |
| `SkipPhoneRegistration` | `true` | Simple Mode skips MFA phone migration |

## Harvest Configuration (Advanced Mode)

```json
"Harvest": {
  "QueueName": "user-ids-to-process",
  "IdsPerMessage": 20,
  "PageSize": 999,
  "MessageVisibilityTimeout": "00:30:00"
}
```

## Phone Registration Configuration

```json
"PhoneRegistration": {
  "QueueName": "phone-registration",
  "ThrottleDelayMs": 400,
  "MessageVisibilityTimeoutSeconds": 120,
  "EmptyQueuePollDelayMs": 5000,
  "MaxEmptyPolls": 3
}
```

| Setting | Default | Notes |
|---------|---------|-------|
| `ThrottleDelayMs` | 400 ms | Increase if sustained 429s. Scale by adding workers. |
| `MessageVisibilityTimeoutSeconds` | 120 s | Message reappears after timeout on crash |
| `MaxEmptyPolls` | 3 | CLI exits after N empty polls |
| `UseFakePhoneWhenMissing` | false | **Load-test only.** Generates synthetic numbers. Never in production. |

## Storage Configuration

```json
"Storage": {
  "ConnectionStringOrUri": "UseDevelopmentStorage=true",
  "AuditTableName": "migrationAudit",
  "UseManagedIdentity": false,
  "AuditMode": "File"
}
```

| AuditMode | Backend | Notes |
|-----------|---------|-------|
| `File` | Local JSONL file | **Default.** Thread-safe, no Azure dependency. |
| `Table` | Azure Table Storage / Azurite | Queryable, production-grade. Requires `Storage Table Data Contributor`. |
| `None` | No-op | Smoke tests only. |

Required roles (Advanced Mode): `Storage Queue Data Contributor`. Add `Storage Table Data Contributor` only if using `AuditMode="Table"`.

## Retry Configuration

```json
"Retry": {
  "MaxRetries": 5,
  "InitialDelayMs": 1000,
  "MaxDelayMs": 30000,
  "BackoffMultiplier": 2.0,
  "UseRetryAfterHeader": true,
  "OperationTimeoutSeconds": 120
}
```

## Telemetry Configuration

```json
"Telemetry": {
  "Enabled": true,
  "UseConsoleLogging": true
}
```

Key metrics: `harvest.users.enqueued`, `WorkerMigrate.UserCreated/Duplicate/Failed`, `PhoneRegistration.Success/Failed/Completed`, `JITAuth.PasswordValidated`.

## MaxConcurrency

| Setting | Default | Scope |
|---------|---------|-------|
| `Migration.MaxConcurrency` | 8 | Parallel calls in worker-migrate and phone-registration |

Increase to 4–8 per instance for higher throughput. For significant scale, run **multiple instances** on separate IPs with dedicated app registrations.
