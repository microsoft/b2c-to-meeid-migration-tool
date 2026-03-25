<#
.SYNOPSIS
    Live monitoring dashboard for an active B2C → EEID migration run.

.DESCRIPTION
    Tails worker and phone-registration JSONL telemetry files, showing
    running counters that refresh every few seconds. Press Ctrl+C to
    stop and print a final summary.

.PARAMETER WorkerCount
    Number of migrate workers to monitor (default: 5).
    Looks for worker1..N-telemetry.jsonl + phone-registration1..N-telemetry.jsonl.

.PARAMETER ConsoleDir
    Directory containing the telemetry files.
    Default: ../src/B2CMigrationKit.Console relative to this script.

.PARAMETER RefreshSeconds
    Seconds between dashboard refreshes (default: 3).

.EXAMPLE
    # Monitor 5 workers, refresh every 3s
    .\Watch-Migration.ps1

    # Monitor 8 workers, refresh every 2s
    .\Watch-Migration.ps1 -WorkerCount 8 -RefreshSeconds 2
#>
param(
    [int]$WorkerCount     = 5,
    [string]$ConsoleDir   = "$PSScriptRoot\..\src\B2CMigrationKit.Console",
    [int]$RefreshSeconds  = 3
)

. (Join-Path $PSScriptRoot "_Common.ps1")

# ─── Helpers ──────────────────────────────────────────────────────────────────

<#
.SYNOPSIS
    Reads a JSONL telemetry file and returns parsed objects.
    Returns empty array if file does not exist.
#>
function Read-TelemetryFile {
    param([string]$Path)

    if (-not (Test-Path $Path)) { return @() }

    $lines = Get-Content $Path -ErrorAction SilentlyContinue
    $objects = @()
    foreach ($line in $lines) {
        if ([string]::IsNullOrWhiteSpace($line)) { continue }
        try {
            $objects += ($line | ConvertFrom-Json)
        }
        catch {
            # Skip malformed lines
        }
    }
    return $objects
}

<#
.SYNOPSIS
    Aggregates counters from an array of telemetry events.
    Returns a hashtable with Success, Failed, Skipped, Throttled, Total, Errors.
#>
function Get-Counters {
    param([object[]]$Events)

    $counters = @{
        Success   = 0
        Failed    = 0
        Skipped   = 0
        Throttled = 0
        Total     = 0
        Errors    = [System.Collections.Generic.List[string]]::new()
    }

    foreach ($evt in $Events) {
        $counters.Total++

        $status = ($evt.Status ?? $evt.Result ?? "").ToString().ToLower()

        switch -Wildcard ($status) {
            "success*"   { $counters.Success++ }
            "skip*"      { $counters.Skipped++ }
            "throttl*"   { $counters.Throttled++ }
            "fail*"      { $counters.Failed++; if ($evt.Error) { $counters.Errors.Add($evt.Error) } }
            "error*"     { $counters.Failed++; if ($evt.Error) { $counters.Errors.Add($evt.Error) } }
            default      { $counters.Success++ }  # Assume success if no failure indicator
        }
    }

    return $counters
}

<#
.SYNOPSIS
    Renders the dashboard to the console.
#>
function Write-Dashboard {
    param(
        [hashtable]$Migrate,
        [hashtable]$Phone,
        [int]$FilesMissing,
        [int]$FilesTotal,
        [datetime]$StartTime
    )

    $elapsed = (Get-Date) - $StartTime
    $elapsedStr = "{0:hh\:mm\:ss}" -f $elapsed

    Clear-Host
    Write-Host "╔══════════════════════════════════════════════════════╗" -ForegroundColor Cyan
    Write-Host "║          B2C → EEID Migration — Live Monitor        ║" -ForegroundColor Cyan
    Write-Host "╠══════════════════════════════════════════════════════╣" -ForegroundColor Cyan
    Write-Host "║  Elapsed: $($elapsedStr.PadRight(41))║" -ForegroundColor Cyan
    Write-Host "╚══════════════════════════════════════════════════════╝" -ForegroundColor Cyan
    Write-Host ""

    if ($FilesMissing -eq $FilesTotal) {
        Write-Warn "⏳ Waiting for telemetry files to appear..."
        Write-Warn "   Expected in: $ConsoleDir"
        Write-Host ""
        return
    }

    # ─── Migrate Workers ──────────────────────────────────────────────────
    Write-Host "  MIGRATE WORKERS" -ForegroundColor White
    Write-Host "  ─────────────────────────────────────────────" -ForegroundColor DarkGray

    $rate = if ($elapsed.TotalSeconds -gt 0) { [math]::Round($Migrate.Success / $elapsed.TotalMinutes, 1) } else { 0 }

    Write-Success "    ✓ Migrated:   $($Migrate.Success)"
    Write-Warn    "    ○ Skipped:    $($Migrate.Skipped)"
    Write-Err     "    ✗ Failed:     $($Migrate.Failed)"

    if ($Migrate.Throttled -gt 0) {
        Write-Host "    ⏱ Throttled:  $($Migrate.Throttled)" -ForegroundColor Yellow
    }

    Write-Host "    ─────────────────────────────────────────" -ForegroundColor DarkGray
    Write-Host "    Total events: $($Migrate.Total)   (~$rate users/min)" -ForegroundColor Gray
    Write-Host ""

    # ─── Phone Registration ───────────────────────────────────────────────
    Write-Host "  PHONE REGISTRATION" -ForegroundColor White
    Write-Host "  ─────────────────────────────────────────────" -ForegroundColor DarkGray

    if ($Phone.Total -eq 0) {
        Write-Host "    (no events yet)" -ForegroundColor DarkGray
    }
    else {
        Write-Success "    ✓ Registered: $($Phone.Success)"
        Write-Warn    "    ○ Skipped:    $($Phone.Skipped)"
        Write-Err     "    ✗ Failed:     $($Phone.Failed)"

        if ($Phone.Throttled -gt 0) {
            Write-Host "    ⏱ Throttled:  $($Phone.Throttled)" -ForegroundColor Yellow
        }

        Write-Host "    ─────────────────────────────────────────" -ForegroundColor DarkGray
        Write-Host "    Total events: $($Phone.Total)" -ForegroundColor Gray
    }

    Write-Host ""

    # ─── Recent Errors ────────────────────────────────────────────────────
    $allErrors = @()
    $allErrors += $Migrate.Errors | Select-Object -Last 3
    $allErrors += $Phone.Errors   | Select-Object -Last 3
    $allErrors = $allErrors | Select-Object -Last 5

    if ($allErrors.Count -gt 0) {
        Write-Host "  RECENT ERRORS (last 5)" -ForegroundColor Red
        Write-Host "  ─────────────────────────────────────────────" -ForegroundColor DarkGray
        foreach ($err in $allErrors) {
            $truncated = if ($err.Length -gt 70) { $err.Substring(0, 67) + "..." } else { $err }
            Write-Err "    $truncated"
        }
        Write-Host ""
    }

    # ─── Files ────────────────────────────────────────────────────────────
    $found = $FilesTotal - $FilesMissing
    Write-Host "  Files: $found/$FilesTotal telemetry files detected" -ForegroundColor DarkGray
    Write-Host "  Press Ctrl+C to stop and show summary." -ForegroundColor DarkGray
}

<#
.SYNOPSIS
    Prints a final summary on exit.
#>
function Write-Summary {
    param(
        [hashtable]$Migrate,
        [hashtable]$Phone,
        [datetime]$StartTime
    )

    $elapsed = (Get-Date) - $StartTime
    $elapsedStr = "{0:hh\:mm\:ss}" -f $elapsed

    Write-Host ""
    Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host "  Migration Monitor — Final Summary" -ForegroundColor Cyan
    Write-Host "  Monitored for: $elapsedStr" -ForegroundColor Cyan
    Write-Host "═══════════════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host ""

    Write-Host "  Migrate:  $($Migrate.Success) success, $($Migrate.Failed) failed, $($Migrate.Skipped) skipped" -ForegroundColor White
    Write-Host "  Phone:    $($Phone.Success) success, $($Phone.Failed) failed, $($Phone.Skipped) skipped" -ForegroundColor White

    $totalOk   = $Migrate.Success + $Phone.Success
    $totalFail = $Migrate.Failed  + $Phone.Failed
    Write-Host ""

    if ($totalFail -eq 0) {
        Write-Success "  ✓ No errors detected."
    }
    else {
        Write-Err "  ✗ $totalFail total failures — review telemetry files or run Analyze-Telemetry.ps1"
    }

    Write-Host ""
}

# ─── Main Loop ────────────────────────────────────────────────────────────────

$startTime = Get-Date

# Build list of expected telemetry files
$migrateFiles = @()
$phoneFiles   = @()
for ($i = 1; $i -le $WorkerCount; $i++) {
    $migrateFiles += Join-Path $ConsoleDir "worker$i-telemetry.jsonl"
    $phoneFiles   += Join-Path $ConsoleDir "phone-registration$i-telemetry.jsonl"
}

$allFiles = $migrateFiles + $phoneFiles

Write-Info "Watching $($allFiles.Count) telemetry files in: $ConsoleDir"
Write-Info "Refresh: every ${RefreshSeconds}s | Workers: $WorkerCount | Ctrl+C to stop"
Write-Host ""

# Track last state for Ctrl+C summary
$lastMigrate = @{ Success = 0; Failed = 0; Skipped = 0; Throttled = 0; Total = 0; Errors = @() }
$lastPhone   = @{ Success = 0; Failed = 0; Skipped = 0; Throttled = 0; Total = 0; Errors = @() }

try {
    while ($true) {
        # ── Read all migrate worker files ──
        $allMigrateEvents = @()
        foreach ($f in $migrateFiles) {
            $allMigrateEvents += Read-TelemetryFile -Path $f
        }
        $lastMigrate = Get-Counters -Events $allMigrateEvents

        # ── Read all phone registration files ──
        $allPhoneEvents = @()
        foreach ($f in $phoneFiles) {
            $allPhoneEvents += Read-TelemetryFile -Path $f
        }
        $lastPhone = Get-Counters -Events $allPhoneEvents

        # ── Count missing files ──
        $missing = ($allFiles | Where-Object { -not (Test-Path $_) }).Count

        # ── Render ──
        Write-Dashboard `
            -Migrate      $lastMigrate `
            -Phone        $lastPhone `
            -FilesMissing $missing `
            -FilesTotal   $allFiles.Count `
            -StartTime    $startTime

        Start-Sleep -Seconds $RefreshSeconds
    }
}
finally {
    # Ctrl+C lands here
    Write-Summary -Migrate $lastMigrate -Phone $lastPhone -StartTime $startTime
}
