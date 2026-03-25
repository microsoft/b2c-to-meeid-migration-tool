# B2C Migration Kit - Architecture Guide

**Audience**: Solutions Architects, Technical Leads, Security Reviewers

---

## Table of Contents

1. [Executive Summary](#1-executive-summary) — Migration modes overview & decision table
2. [System Overview](#2-system-overview) — Architecture diagrams, Simple Mode & Advanced Mode data flows
3. [Design Principles](#3-design-principles)
4. [Component Architecture](#4-component-architecture)
5. [Just-In-Time (JIT) Migration](#5-just-in-time-jit-migration)
6. [Security Architecture](#6-security-architecture)
7. [Scalability & Performance](#7-scalability--performance)
8. [Deployment & Operations](#8-deployment--operations)

---

## 1. Executive Summary

The **B2C Migration Kit** migrates user identities from **Azure AD B2C** to **Microsoft Entra External ID**.

The kit has two independent concerns:

1. **Bulk user migration** — export/import user profiles from B2C to External ID, with two modes:
   - **Simple Mode — Export/Import**: Simple local-file pipeline (`export` → local JSON files → `import`). Best for small tenants, no MFA phone migration needed. No Azure storage infrastructure required.
   - **Advanced Mode — Workers**: Queue-based parallel pipeline (`harvest` → `worker-migrate` → `phone-registration`). Best for large tenants, full MFA phone migration, parallel scaling. Requires Azure Queue Storage for worker coordination.
2. **JIT Password Migration** — Seamless password validation on first login via Custom Authentication Extension. Works independently of which bulk mode you choose — it runs as an Azure Function triggered on each user's first login after bulk migration.

### Choose Your Bulk Migration Mode

| Factor | Simple Mode (Export/Import) | Advanced Mode (Workers) |
|--------|----------------------|-------------------|
| **Best for** | Small/medium tenants <500K users, no MFA phones | Large tenants, MFA phone migration |
| **Infrastructure** | Local JSON files only (no Azure storage) | Queue Storage (+ optional Table Storage for audit) |
| **Parallelism** | Single-threaded | N worker pairs, configurable concurrency |
| **MFA phones** | ❌ Not supported | ✅ Full phone method migration |
| **Commands** | `export` → `import` (2 steps) | `harvest` → `worker-migrate` → `phone-registration` (3 steps) |
| **Complexity** | Low | Medium |

---

## 2. System Overview

### High-Level Architecture

```
┌─────────────────────────────────────────────────────────────────┐
│                    Azure Subscription                           │
│                                                                 │
│  ┌──────────────────────────┐  ┌──────────────┐               │
│  │ Console App              │  │Azure Function│               │
│  │  Simple Mode: Export/Import   │  │(JIT Auth)    │               │
│  │  Advanced Mode: Harvest/Worker/ │  │              │               │
│  │          PhoneReg        │  │              │               │
│  └──────┬───────────────────┘  └──────┬───────┘               │
│         │                             │                        │
│  ┌──────▼─────────────────────────────▼───────────────┐       │
│  │                 Shared Core Library                 │       │
│  │   (Services, Models, Orchestrators, Abstractions)   │       │
│  └──────┬───────────┬───────────┬──────────┬──────────┘       │
│         ▼           ▼           ▼          ▼                   │
│  ┌──────────┐ ┌──────────┐                                    │
│  │ Queue    │ │Key Vault │                                    │
│  │ Storage  │ │          │                                    │
│  │(Adv Mode)│ │          │                                    │
│  └──────────┘ └──────────┘                                    │
└─────────────────────────────────────────────────────────────────┘
         │                           │
         ▼                           ▼
┌─────────────────┐         ┌─────────────────┐
│ Azure AD B2C    │         │ External ID     │
│ (Source Tenant) │         │ (Target Tenant) │
└─────────────────┘         └─────────────────┘
```

### Data Flow

The kit supports two migration pipelines. Choose based on your scenario (see [Choose Your Migration Mode](#choose-your-migration-mode)).

---

### Simple Mode — Export/Import Pipeline

A simple two-step local-file pipeline for straightforward migrations without MFA phone migration. No Azure storage infrastructure required.

#### Step 1 — `export` (run once)

```
B2C Tenant → GET /users?$select={fields}&$top={pageSize}
  └─ ExportOrchestrator
     └─► Local file: exports/page-{N}.json
```

Pages all B2C users with configurable `$select` fields, writes each page as a local JSON file. Supports optional client-side filtering by `displayName`/`userPrincipalName` pattern. Exits when all pages are processed.

- **Config**: `Export.SelectFields`, `Export.FilterPattern` (optional)
- **Permissions**: B2C `User.Read.All` (Application)

#### Step 2 — `import` (run once)

```
Local files: exports/*.json
  └─ ImportOrchestrator
     ├─ Read user JSON from each file
     ├─ Transform: UPN domain rewrite, extension attrs, email identity, random password
     ├─ POST /users → EEID
     │   ├─ 201 Created  → audit(Created)
     │   ├─ 409 Conflict → audit(Duplicate)
     │   └─ Other error  → audit(Failed)
     └─► Local audit JSONL file (default) or Azure Table Storage (optional)
```

Reads exported files sequentially, transforms each user profile, creates in EEID. Audit results written to local JSONL files by default (`AuditMode="File"`). Single-threaded — no queue coordination needed.

- **Config**: `Import.ExtensionAttributes`
- **Permissions**: B2C `User.Read.All` (for export), EEID `User.ReadWrite.All` (Application)

> **Limitations**: No MFA phone migration, no parallel scaling. For large tenants or MFA scenarios, use Advanced Mode.

---

### Advanced Mode — Worker Pipeline

A queue-based parallel pipeline for large-scale migrations with full MFA phone support.

#### Step 1 — `harvest` (run once)

```
B2C Tenant → GET /users?$select=id&$top=999
  └─ HarvestOrchestrator
     └─► Queue: user-ids-to-process  (JSON arrays of 20 IDs per message)
```

Pages B2C with `$select=id` (cheapest Graph query), splits into batches of 20, enqueues each. Exits when all pages are processed.

#### Step 2a — `worker-migrate` (run N parallel instances)

```
Queue: user-ids-to-process
└─ WorkerMigrateOrchestrator (independent app registration per instance)
   ├─ GET /$batch → B2C (up to 20 full profiles per batch)
   ├─ Transform: UPN domain rewrite, extension attrs, email identity, random password
   ├─ POST /users → EEID
   │   ├─ 201 Created  → audit(Created)   + enqueue phone task
   │   ├─ 409 Conflict → audit(Duplicate) + enqueue phone task
   │   └─ Other error  → audit(Failed, errorCode, errorMessage)
   ├─► Audit: local JSONL file (default) or Azure Table Storage (optional)
   └─► Queue: phone-registration  ({ B2CUserId, EEIDUpn } — no phone number stored)
```

#### Step 2b — `phone-registration` (run M parallel instances)

```
Queue: phone-registration
└─ PhoneRegistrationWorker (independent app registrations for B2C and EEID)
   ├─ GET /users/{B2CUserId}/authentication/phoneMethods → B2C
   ├─ If phone found: POST to EEID → audit(PhoneRegistered)
   ├─ If no phone: audit(PhoneSkipped)
   └─ 409 Conflict → treated as success (idempotent)
```

Phone numbers are fetched at drain time — never stored in the queue (PII protection).

> **Throttle note**: The `phoneMethods` API has a different throttle budget than the main Users API (see [Microsoft Graph throttling guidance](https://learn.microsoft.com/graph/throttling)). Default `ThrottleDelayMs` is **400 ms**. Scale by adding workers with dedicated app registration pairs.

#### Step 3 — JIT Migration (first login, Azure Function)

```
User Login → EEID checks RequiresMigration = true
  └─ Custom Authentication Extension → Azure Function
     ├─ Decrypt password (RSA private key)
     ├─ Reverse UPN transform → B2C UPN
     ├─ POST /oauth2/v2.0/token (ROPC) → B2C
     │   ├─ Valid   → MigratePassword → EEID sets password + RequiresMigration=false
     │   └─ Invalid → BlockSignIn
     └─ Subsequent logins: direct EEID auth (no JIT call)
```

---

## 2.1 End-to-End Pipeline Narrative

This section walks through both migration pipelines from start to finish, explaining **why** each stage exists and how they connect.

### Simple Mode — Export/Import Narrative

Simple Mode is a straightforward two-step pipeline:

1. **Export** pages all B2C users and writes full profiles to local JSON files. Each page becomes one file (~999 users). Optional client-side filtering (`FilterPattern`) limits export to matching users.
2. **Import** reads each file sequentially, transforms user profiles (UPN rewrite, extension attribute mapping, email identity, random password with `RequiresMigration` flag), and creates each user in EEID via `POST /users`. Audit results are written to local JSONL files by default.

**Why local files?** For small tenants, the overhead of queues and cloud storage is unnecessary. Local files provide a simple checkpoint — if import fails mid-file, re-run skips duplicates (409 = idempotent). Export files also serve as a backup of the source data. No Azure storage infrastructure is needed.

### Advanced Mode — Worker Pipeline Narrative

### Stage 1 — Harvest (single instance, run once)

The harvest step pages all B2C users using the cheapest possible Graph query (`$select=id`, page size 999). It splits the collected IDs into batches of 20 and enqueues each batch as a single message to the `user-ids-to-process` queue. The harvest process exits when all pages have been processed.

**Why batch of 20?** Graph `$batch` requests support up to 20 individual requests per call, so each queue message maps directly to one `$batch` call downstream.

### Stage 2 — Worker-Migrate (N parallel instances)

Each worker-migrate instance dequeues a batch message, fetches full user profiles from B2C via a single `POST /$batch` request (up to 20 profiles), transforms each profile to the External ID schema (UPN domain rewrite, extension attributes, email identity, random password), and creates the user in EEID via `POST /users`.

After creating (or detecting a duplicate of) each user, the worker **enqueues a phone-registration message** containing `{ B2CUserId, EEIDUpn }` — no phone number, just references. Phone registration is a separate stage because:

1. **Dependency**: The EEID user must exist before a phone method can be registered on it.
2. **Rate limit isolation**: The `phoneMethods` API has its own throttle budget. Running phone registration inline would bottleneck the entire pipeline.

### Stage 3 — Phone-Registration Worker (N parallel instances)

Each phone-registration worker reads from the queue populated by **its paired worker-migrate instance**. For each message it fetches the phone number from B2C (`GET /authentication/phoneMethods`) and registers it in EEID (`POST /authentication/phoneMethods`). Phone numbers are fetched at drain time — never stored in the queue (PII protection).

The worker runs with `ThrottleDelayMs` (default 400 ms) to stay under the `phoneMethods` rate limit. It treats 409 Conflict as success (idempotent).

### Stage 4 — Telemetry & Audit

All workers emit structured JSONL telemetry to local files (`worker{N}-telemetry.jsonl`, `phone-registration{N}-telemetry.jsonl`). Audit records default to local JSONL files (`AuditMode="File"`); optionally, set `AuditMode="Table"` to write to Azure Table Storage for queryable audit. This enables post-run analysis via `Analyze-Telemetry.ps1` and full traceability of every user processed.

### Stage 5 — Scaling

Throughput scales along two axes:

1. **More worker pairs** — each pair consists of one worker-migrate instance + one phone-registration instance, with **dedicated app registration pairs** (B2C + EEID) and **per-pair queues** for phone registration (e.g., `phone-reg-w1`, `phone-reg-w2`). This multiplies the API throttle budget linearly.
2. **More concurrency within a worker** — increase `MaxConcurrency` (default 1). Beyond a certain threshold per app registration, latency spikes without throughput gains — tune based on your observed telemetry.

### Per-Worker Queue Pairing

> **Note**: Per-pair queues are a **configuration pattern**, not an automatic feature. By default, all workers share a single `phone-registration` queue (suitable for single-instance or smoke-test runs). For multi-instance production deployments, configure each worker pair with a distinct `PhoneRegistration.QueueName` (e.g., `phone-reg-w1`, `phone-reg-w2`) to achieve throttle isolation.

Each worker-migrate instance communicates with its dedicated phone-registration worker through a **per-pair queue**, not a shared queue:

```
Worker 1  (App Reg B2C-1 / EEID-1)  ──► queue: phone-reg-w1  ──► Phone Worker 1
Worker 2  (App Reg B2C-2 / EEID-2)  ──► queue: phone-reg-w2  ──► Phone Worker 2
Worker 3  (App Reg B2C-3 / EEID-3)  ──► queue: phone-reg-w3  ──► Phone Worker 3
Worker N  (App Reg B2C-N / EEID-N)  ──► queue: phone-reg-wN  ──► Phone Worker N
```

**Why per-pair queues?**

- **Throttle isolation**: Each phone-registration worker uses its own app registration.
- **Clean telemetry**: Per-worker JSONL files stay isolated, making analysis straightforward.
- **No cross-contamination**: If a worker restarts, only its own queue has stale messages.

> **⚠️ Stale messages**: If you re-run a migration without clearing per-worker queues, the phone-registration workers will process leftover messages from the prior run. This causes >100% coverage in telemetry analysis. Clear queues before re-running: `az storage queue clear --name phone-reg-w1 --connection-string "UseDevelopmentStorage=true"`.

---

## 3. Design Principles

> **Note**: Infrastructure (VNet, Private Endpoints, Key Vault) is implemented in `infra/` and deployed via Deploy-All.ps1.

| Principle | Details |
|-----------|---------|
| **Modular Architecture** | Shared Core Library (business logic) + Console (CLI) + Azure Functions (JIT). Zero hosting-specific dependencies in Core. |
| **Security First** | Private Endpoints, Managed Identity, optional Key Vault integration. Encryption at rest + in transit (TLS 1.2+). Least privilege permissions. |
| **Observability** | Structured logging (console + local JSONL audit by default, optional Table Storage), run summaries, JSONL telemetry files. |
| **Reliability** | Idempotent operations, graceful degradation, checkpoint/resume via queue visibility timeouts, Polly exponential backoff + jitter on 429s. |
| **Scalability** | Multi-app parallelization via per-worker-pair queues (see [§2.1](#21-end-to-end-pipeline-narrative)). Each worker pair has dedicated app registrations (B2C + EEID) and a per-pair phone-registration queue. Two scaling axes: add more worker pairs (linear throughput), or increase `MaxConcurrency` within a worker. |

---

## 4. Component Architecture

### Core Library Structure

```
B2CMigrationKit.Core/
├── Abstractions/          # IOrchestrator, IGraphClient, IQueueClient, ITableStorageClient, etc.
├── Configuration/         # MigrationOptions, B2COptions, ExternalIdOptions, StorageOptions, etc.
├── Models/                # UserProfile, MigrationAuditRecord, RunSummary, PhoneRegistrationMessage, etc.
├── Services/
│   ├── Orchestrators/     # ExportOrchestrator, ImportOrchestrator (Simple Mode), HarvestOrchestrator, WorkerMigrateOrchestrator, PhoneRegistrationWorker (Advanced Mode), JitMigrationService
│   ├── Infrastructure/    # GraphClient, QueueStorageClient, TableStorageClient, BlobStorageClient, etc.
│   └── Observability/     # TelemetryService
└── Extensions/            # ServiceCollectionExtensions (DI registration)
```

### Dependency Injection

All services use constructor injection with interface-based abstractions. Keyed services distinguish B2C vs EEID graph clients:

```csharp
services.AddCoreServices(configuration);

public class WorkerMigrateOrchestrator : IOrchestrator
{
    public WorkerMigrateOrchestrator(
        [FromKeyedServices("b2c")] IGraphClient b2cClient,
        [FromKeyedServices("externalId")] IGraphClient externalIdClient,
        IQueueClient queueClient,
        ITableStorageClient auditClient,
        ITelemetryService telemetry,
        ILogger<WorkerMigrateOrchestrator> logger) { }
}
```

---

## 5. Just-In-Time (JIT) Migration

### Overview

JIT enables seamless password validation on first External ID login:

1. User logs in → EEID checks `RequiresMigration = true`
2. Custom Authentication Extension calls Azure Function with encrypted password + UPN
3. Function decrypts password (RSA private key from Key Vault or inline configuration)
4. Function reverses UPN transform: `user@externalid.com` → `user@b2c.com`
5. Function validates via ROPC against B2C
6. If valid → `MigratePassword` (EEID sets password, clears flag). If invalid → `BlockSignIn`

**UPN Flow**:
```
Import:  user@b2c.com → user@externalid.com  (preserve local part)
JIT:     user@externalid.com → user@b2c.com  (reverse using same local part)
```

### Security Measures

| Layer | Control |
|-------|---------|
| **Encryption at rest** | RSA private key in Key Vault (recommended) or inline configuration. Passwords never stored/logged. |
| **Encryption in transit** | Password field RSA-encrypted by Custom Extension. All traffic TLS 1.2+. |
| **AuthN: EEID → Function** | Azure AD bearer token, audience = Custom Extension app ID URI |
| **AuthN: Function → B2C** | ROPC flow (ClientId + ClientSecret). No Graph permissions needed. |
| **AuthN: Function → EEID** | Managed Identity or Service Principal, `User.ReadWrite.All` |
| **Replay protection** | Nonce in encrypted payload, validated by function |
| **Timeout** | EEID hard limit: 2s. Function internal: 1.5s (configurable). Exceeds → `BlockSignIn`. |

---

## 6. Security Architecture

> **⚠️ STATUS**: v1.0 includes TLS 1.2+, client secret auth, no secrets in code. 

### Service Principal Permissions

| Process | Mode | Tenant | Permission | Type |
|---|---|---|---|---|
| `export` | Simple | B2C | `User.Read.All` | Application |
| `import` | Simple | EEID | `User.ReadWrite.All` | Application |
| `harvest` | Advanced | B2C | `User.Read.All` | Application |
| `worker-migrate` | Advanced | B2C | `User.Read.All` | Application |
| `worker-migrate` | Advanced | EEID | `User.ReadWrite.All` | Application |
| `phone-registration` | Advanced | B2C | `UserAuthenticationMethod.Read.All` | Application |
| `phone-registration` | Advanced | EEID | `UserAuthenticationMethod.ReadWrite.All` | Application |
| JIT Function | Both | EEID | `User.ReadWrite.All` | Application |

> Admin consent required for all. `Directory.ReadWrite.All` / `Directory.Read.All` are **not required** — least-privilege approach.

### Data Protection

- **At rest**: Azure Storage Service Encryption (SSE). Optional Key Vault integration for sensitive configuration (secrets, RSA keys)
- **In transit**: TLS 1.2+ for all connections, strict certificate validation
- **Secrets**: Configuration files with gitignored credentials (default) or Key Vault integration (optional, enabled via `Migration:KeyVault:Enabled`)

### Audit & Compliance

- Function invocation logs (correlation IDs, user IDs, results)
- External ID sign-in audit logs (30-day retention, export for long-term)
- Migration audit: local JSONL files (default) or Azure Table Storage (optional, queryable)
- Optional: Key Vault audit logs when Key Vault integration is enabled

---

## 7. Scalability & Performance

### Throughput Model

Migration throughput scales along two axes:

| Axis | Mechanism | Effect |
|------|-----------|--------|
| **More worker pairs** | Add worker-migrate + phone-registration instances with dedicated app registrations | Linear throughput increase (each pair gets its own Graph API throttle budget) |
| **Higher concurrency** | Increase `MaxConcurrency` within a worker | Sub-linear gains; tune based on observed telemetry |

### Phone Registration Throughput

The `phoneMethods` API has a different throttle budget than the main Users API. Each phone-registration worker with a dedicated app registration adds its own quota. Scale by adding more phone-worker VMs. See [Microsoft Graph throttling guidance](https://learn.microsoft.com/graph/throttling) for current limits.

### Rate Limiting Strategy

- **429 responses**: Polly retry with exponential backoff + jitter. Honors `Retry-After` header.
- **Per-app quotas**: Each worker pair uses independent app registrations to multiply the throttle budget.
- **Phone throttle**: Fixed `ThrottleDelayMs` (default 400 ms) prevents sustained 429s on the phone API.

---

## 8. Deployment & Operations

### Development Environment

```
Developer Workstation
├── Console App (harvest, worker-migrate, phone-registration)
├── Azure Function (localhost:7071) + ngrok tunnel
├── Azurite (local storage emulator)
└── External ID Test Tenant (Custom Extension → ngrok URL)
```

Fast iteration, full debugging, inline RSA keys, no Key Vault dependency.

### Production Environment

All resources deploy via Bicep (`infra/`) and the Deploy-All.ps1 script. No public endpoints; all data-plane traffic stays inside the VNet via Private Endpoints.

```
┌─ VNet 10.0.0.0/16 ─────────────────────────────────────────────┐
│                                                                  │
│  workers (10.0.1.0/24)          private-endpoints (10.0.2.0/24) │
│  ┌──────────┐ ┌──────────┐     ┌─────────────────────────────┐  │
│  │ worker-1 │ │ worker-2 │     │ PE: Queue Storage            │  │
│  │ worker-3 │ │ worker-4 │     │ PE: Key Vault               │  │
│  └────┬─────┘ └────┬─────┘     └─────────────────────────────┘  │
│       │             │                                            │
│  AzureBastionSubnet (10.0.3.0/26)                               │
│  ┌────────────────────┐                                          │
│  │ Bastion (Standard) │ ← SSH tunnel from developer terminal    │
│  └────────────────────┘                                          │
│                                                                  │
│  NAT Gateway ← outbound HTTPS to Graph API                      │
└──────────────────────────────────────────────────────────────────┘
```

**Components**:

- **5× Ubuntu 22.04 VMs** (Standard_B2s) — 1 master (harvest) + 2 user-workers (worker-migrate) + 2 phone-workers (phone-registration)
- **Storage Account** — Queue Storage (work item coordination for Advanced Mode). Audit defaults to local JSONL files; optionally use Table Storage (`AuditMode="Table"`). All via Private Endpoints.
- **Key Vault** (optional) — can store client secrets and RSA keys per worker. RBAC-only, PE access. When not enabled, secrets are stored in local `appsettings` files.
- **Azure Bastion** (Standard, tunneling enabled) — SSH access without public IPs. Optional; can be stopped to save cost.
- **NAT Gateway** — controlled outbound for Graph API calls.

**VM Managed Identity roles**: Storage Queue Data Contributor. Add Key Vault Secrets User if using Key Vault integration. Add Storage Table Data Contributor if using `AuditMode="Table"`.

### Deployment Workflow

1. **Deploy Infrastructure** via Deploy-All.ps1 — provisions all Azure resources via Bicep and provisions VMs
2. **Configure workers** — use Configure-Worker.sh on each VM to set up credentials interactively
3. **Run migration** via Bastion SSH tunnel:
   ```bash
   ./scripts/Connect-Worker.ps1 -WorkerIndex 1   # opens tunnel on port 2201
   ssh -p 2201 azureuser@localhost                # in another terminal
   cd /opt/b2c-migration/app
   ./B2CMigrationKit.Console harvest --config appsettings.json
   ./B2CMigrationKit.Console worker-migrate --config appsettings.json
   ```

See [`infra/README.md`](../infra/README.md) for the full runbook.

### Telemetry

No App Insights dependency. Workers use two telemetry channels:

- **Local JSONL files** — structured audit records per user (status, timestamps, errors). Default and primary observability source (`AuditMode="File"`). Optionally use Azure Table Storage (`AuditMode="Table"`) for queryable audit.
- **Console logging** (`ILogger`) — stdout for real-time debugging via Bastion SSH.

Query audit records via Azure Storage Explorer or `az storage entity query`.


