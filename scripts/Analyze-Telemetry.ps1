<#
.SYNOPSIS
    Analyzes worker + phone-registration telemetry JSONL files.

.PARAMETER WorkerCount
    Number of migrate workers to aggregate (default: 5).
    Loads worker1..N-telemetry.jsonl + phone-registration1..N-telemetry.jsonl.

.PARAMETER ConsoleDir
    Directory containing the telemetry files.
    Default: ../src/B2CMigrationKit.Console relative to this script.

.PARAMETER TelemetryFile
    Analyze a single JSONL file instead of aggregating all workers.
    When set, phone registration section is skipped.

.PARAMETER OutputMarkdown
    Path to write a Markdown report file. If omitted, only console output is produced.

.EXAMPLE
    # Aggregate all 5 workers + phone workers (default)
    .\Analyze-Telemetry.ps1

    # Aggregate 8 workers
    .\Analyze-Telemetry.ps1 -WorkerCount 8

    # Single file (backward compat)
    .\Analyze-Telemetry.ps1 -TelemetryFile ..\src\B2CMigrationKit.Console\worker2-telemetry.jsonl
#>
param(
    [int]$WorkerCount = 5,
    [string]$ConsoleDir = "$PSScriptRoot\..\src\B2CMigrationKit.Console",
    [string]$TelemetryFile = "",
    [string]$OutputMarkdown = ""
)

# ── Helper: load one or more JSONL files into a flat string array ──────────────
function Read-TelemetryFiles {
    param([string[]]$Paths)
    $all = [System.Collections.Generic.List[string]]::new()
    foreach ($p in $Paths) {
        if (Test-Path $p) {
            [System.IO.File]::ReadAllLines((Resolve-Path $p)) | ForEach-Object { $all.Add($_) }
        }
    }
    return $all.ToArray()
}

# ── Determine mode ─────────────────────────────────────────────────────────────
$singleFileMode = $TelemetryFile -ne ""

if ($singleFileMode) {
    $resolved = Resolve-Path $TelemetryFile -ErrorAction Stop
    $migrateLines = [System.IO.File]::ReadAllLines($resolved)
    $phoneLines   = @()
    Write-Host "Mode   : single file"
    Write-Host "File   : $resolved"
} else {
    $consoleResolved = Resolve-Path $ConsoleDir -ErrorAction Stop
    $migratePaths = 1..$WorkerCount | ForEach-Object { Join-Path $consoleResolved "worker$_-telemetry.jsonl" }
    $phonePaths   = 1..$WorkerCount | ForEach-Object { Join-Path $consoleResolved "phone-registration$_-telemetry.jsonl" }

    $migrateLines = Read-TelemetryFiles -Paths $migratePaths
    $phoneLines   = Read-TelemetryFiles -Paths $phonePaths

    $migrateFound = ($migratePaths | Where-Object { Test-Path $_ }).Count
    $phoneFound   = ($phonePaths   | Where-Object { Test-Path $_ }).Count
    Write-Host "Mode        : multi-worker ($WorkerCount workers)"
    Write-Host "Migrate files loaded : $migrateFound / $WorkerCount  ($($migrateLines.Count) lines)"
    Write-Host "Phone files loaded   : $phoneFound / $WorkerCount  ($($phoneLines.Count) lines)"
}

# ── Stats helper ───────────────────────────────────────────────────────────────
function Stats($label, [int[]]$a) {
    if ($a.Count -eq 0) { Write-Host "  $label — no data"; return }
    $s   = $a | Sort-Object
    $n   = $s.Count
    $avg = [Math]::Round(($a | Measure-Object -Average).Average)
    $min = $s[0]; $max = $s[-1]
    $p50 = $s[[int]($n * .50)]
    $p90 = $s[[int]($n * .90)]
    $p95 = $s[[int]($n * .95)]
    $p99 = $s[[int]($n * .99)]
    Write-Host ("  {0,-26} n={1,4}  avg={2,6}ms  min={3,5}  p50={4,5}  p90={5,6}  p95={6,6}  p99={7,6}  max={8,6}" `
        -f $label, $n, $avg, $min, $p50, $p90, $p95, $p99, $max)
}

# ── Markdown stats row helper ─────────────────────────────────────────────────
function StatsMd($label, [int[]]$a) {
    if ($a.Count -eq 0) { return "| $label | — | — | — | — | — | — | — | — |" }
    $s   = $a | Sort-Object
    $n   = $s.Count
    $avg = [Math]::Round(($a | Measure-Object -Average).Average)
    $min = $s[0]; $max = $s[-1]
    $p50 = $s[[int]($n * .50)]
    $p90 = $s[[int]($n * .90)]
    $p95 = $s[[int]($n * .95)]
    $p99 = $s[[int]($n * .99)]
    return "| $label | $n | $avg | $min | $p50 | $p90 | $p95 | $p99 | $max |"
}

# ═══════════════════════════════════════════════════════════════════════════════
# MIGRATE WORKERS
# ═══════════════════════════════════════════════════════════════════════════════
$fetches  = [System.Collections.Generic.List[int]]::new()
$userMs   = [System.Collections.Generic.List[int]]::new()
$bB2c     = [System.Collections.Generic.List[int]]::new()
$bEeidAvg = [System.Collections.Generic.List[int]]::new()
$bEeidMax = [System.Collections.Generic.List[int]]::new()
$migrateTs           = [System.Collections.Generic.List[datetime]]::new()
$lastStartedTs       = $null
$userApiMs           = [System.Collections.Generic.List[int]]::new()
$migrateThrottledB2c  = 0
$migrateThrottledEeid = 0

# First pass: find the timestamp of the last WorkerMigrate.Started (= last run)
foreach ($l in $migrateLines) {
    if ($l -match '"name":"WorkerMigrate\.Started"' -and $l -match '"ts":"([^"]+)"') {
        $tsRaw = $Matches[1] -replace '\u002B', '+'
        try { $lastStartedTs = [datetime]$tsRaw } catch {}
    }
}

# Second pass: only process events from the last run
foreach ($l in $migrateLines) {
    if ($l -match '"ts":"([^"]+)"') {
        $tsRaw = $Matches[1] -replace '\u002B', '+'
        try {
            $ts = [datetime]$tsRaw
            if ($lastStartedTs -and $ts -lt $lastStartedTs) { continue }
            $migrateTs.Add($ts)
        } catch {}
    }
    if ($l -match '"name":"WorkerMigrate\.B2CFetch"') {
        if ($l -match '"fetchMs":"(\d+)"') { $fetches.Add([int]$Matches[1]) }
    } elseif ($l -match '"name":"WorkerMigrate\.UserCreated"') {
        if ($l -match '"eeidCreateMs":"(\d+)"') { $userMs.Add([int]$Matches[1]) }
        if ($l -match '"eeidApiMs":"(\d+)"')    { $userApiMs.Add([int]$Matches[1]) }
    } elseif ($l -match '"name":"Graph\.Throttled"') {
        if ($l -match '"tenantRole":"B2C"') { $migrateThrottledB2c++ }
        else                                { $migrateThrottledEeid++ }
    } elseif ($l -match '"name":"WorkerMigrate\.BatchDone"') {
        if ($l -match '"b2cFetchMs":"(\d+)"')  { $bB2c.Add([int]$Matches[1]) }
        if ($l -match '"eeidAvgMs":"(\d+)"')   { $bEeidAvg.Add([int]$Matches[1]) }
        if ($l -match '"eeidMaxMs":"(\d+)"')   { $bEeidMax.Add([int]$Matches[1]) }
    }
}

$wall = [int[]]@(for ($i = 0; $i -lt $bB2c.Count; $i++) { $bB2c[$i] + $bEeidMax[$i] })

Write-Host ""
Write-Host "════════════════════════════════════════════" -ForegroundColor Cyan
Write-Host " MIGRATE WORKERS" -ForegroundColor Cyan
Write-Host "════════════════════════════════════════════" -ForegroundColor Cyan

Write-Host ""
Write-Host "=== LATENCY BY COMPONENT (ms) ==="
Stats "B2C fetch    (per batch)"   ([int[]]$bB2c)
Stats "EEID create  (pure API)"    ([int[]]$userApiMs)
Stats "EEID create  (total op)"    ([int[]]$userMs)
Stats "EEID max     (per batch)"   ([int[]]$bEeidMax)
Stats "EEID avg     (per batch)"   ([int[]]$bEeidAvg)
Stats "Wall time  (b2c+eeid_max)" $wall

Write-Host ""
Write-Host "=== SHARE OF WALL TIME ==="
if ($bB2c.Count -gt 0) {
    $sumB2c  = ($bB2c    | Measure-Object -Sum).Sum
    $sumEeid = ($bEeidMax | Measure-Object -Sum).Sum
    $sumWall = ($wall     | Measure-Object -Sum).Sum
    Write-Host ("  B2C fetch  : {0,8:N1}s  ({1,3}% of wall)" -f ($sumB2c/1000),  [Math]::Round($sumB2c*100/$sumWall))
    Write-Host ("  EEID create: {0,8:N1}s  ({1,3}% of wall)" -f ($sumEeid/1000), [Math]::Round($sumEeid*100/$sumWall))
    Write-Host ("  Total wall : {0,8:N1}s  (sum across {1} batches)" -f ($sumWall/1000), $bB2c.Count)
}

Write-Host ""
Write-Host "=== THROUGHPUT ==="
if ($migrateTs.Count -ge 2) {
    $t0 = if ($lastStartedTs) { $lastStartedTs } else { ($migrateTs | Sort-Object)[0] }
    $t1 = ($migrateTs | Sort-Object)[-1]
    $elapsed = ($t1 - $t0).TotalSeconds
    $runNote = if ($lastStartedTs) { " (from last WorkerMigrate.Started)" } else { " (from first event)" }
    Write-Host "  Run start   : $t0$runNote"
    Write-Host "  Last event  : $t1"
    Write-Host ("  Elapsed     : {0:N1}s" -f $elapsed)
    if ($elapsed -gt 0 -and $userMs.Count -gt 0) {
        Write-Host ("  Users/sec   : {0:N2}" -f ($userMs.Count / $elapsed))
        Write-Host ("  Users/min   : {0:N0}" -f ($userMs.Count / $elapsed * 60))
    }
}

Write-Host ""
Write-Host "=== THEORETICAL MAX (20 users/batch) ==="
if ($wall.Count -gt 0) {
    $avgBatch = [Math]::Round(($wall | Measure-Object -Average).Average)
    $minBatch = ($wall | Measure-Object -Minimum).Minimum
    Write-Host ("  At avg wall {0}ms/batch => {1:N1} users/s  ({2:N0} users/min)" `
        -f $avgBatch, (20/$avgBatch*1000), (20/$avgBatch*60000))
    Write-Host ("  At min wall {0}ms/batch => {1:N1} users/s  ({2:N0} users/min)" `
        -f $minBatch, (20/$minBatch*1000), (20/$minBatch*60000))
}

Write-Host ""
Write-Host "=== TAIL LATENCY (EEID create > 1000ms) ==="
$slowCount = ($migrateLines | Where-Object {
    $_ -match '"name":"WorkerMigrate\.UserCreated"' -and
    $_ -match '"eeidCreateMs":"(\d+)"' -and [int]$Matches[1] -gt 1000
}).Count
if ($userMs.Count -gt 0) {
    Write-Host ("  Slow users (>1s): {0} / {1}  ({2:N1}%)" `
        -f $slowCount, $userMs.Count, ($slowCount * 100.0 / $userMs.Count))
}
Write-Host ""
Write-Host "=== THROTTLES (429) ==="
$migTot = $migrateThrottledB2c + $migrateThrottledEeid
Write-Host ("  Graph.Throttled (B2C  - batch users): {0}" -f $migrateThrottledB2c)
Write-Host ("  Graph.Throttled (EEID - create user): {0}" -f $migrateThrottledEeid)
if ($migTot -gt 0) {
    Write-Host "  ⚠ Throttles detected in migrate workers" -ForegroundColor Yellow
}
# ═══════════════════════════════════════════════════════════════════════════════
# PHONE REGISTRATION WORKERS
# ═══════════════════════════════════════════════════════════════════════════════
if ($phoneLines.Count -gt 0) {

    $phB2cGet    = [System.Collections.Generic.List[int]]::new()  # b2cGetPhoneMs (success only)
    $phB2cApiAll = [System.Collections.Generic.List[int]]::new()  # b2cGetPhoneMs from B2CApiCall (all calls)
    $phEeidPost  = [System.Collections.Generic.List[int]]::new()  # eeidRegisterMs (success only)
    $phEeidApiAll = [System.Collections.Generic.List[int]]::new() # eeidRegisterMs from EEIDApiCall (success + failed)
    $phTotal     = [System.Collections.Generic.List[int]]::new()  # totalMs (success only)
    $phSkipB2c   = [System.Collections.Generic.List[int]]::new()  # b2cGetPhoneMs (skipped — no phone in B2C)
    $phoneTs     = [System.Collections.Generic.List[datetime]]::new()
    $lastPhoneStartedTs = $null
    $phSucceeded = 0
    $phSkipped   = 0
    $phFailed    = 0
    $phThrottled = 0
    $phThrottledB2c  = 0
    $phThrottledEeid = 0
    $phFailedStepB2c  = 0
    $phFailedStepEeid = 0
    # Per-error-code breakdown for failures
    $phErrCodes  = @{}

    # First pass: find the timestamp of the last PhoneRegistration.Started (= last run)
    foreach ($l in $phoneLines) {
        if ($l -match '"name":"PhoneRegistration\.Started"' -and $l -match '"ts":"([^"]+)"') {
            $tsRaw = $Matches[1] -replace '\u002B', '+'
            try { $lastPhoneStartedTs = [datetime]$tsRaw } catch {}
        }
    }

    # Second pass: only process events from the last run
    foreach ($l in $phoneLines) {
        if ($l -match '"ts":"([^"]+)"') {
            $tsRaw = $Matches[1] -replace '\u002B', '+'
            try {
                $ts = [datetime]$tsRaw
                if ($lastPhoneStartedTs -and $ts -lt $lastPhoneStartedTs) { continue }
                $phoneTs.Add($ts)
            } catch {}
        }

        if ($l -match '"name":"PhoneRegistration\.Success"') {
            $phSucceeded++
            if ($l -match '"b2cGetPhoneMs":"(\d+)"')  { $phB2cGet.Add([int]$Matches[1]) }
            if ($l -match '"eeidRegisterMs":"(\d+)"') { $phEeidPost.Add([int]$Matches[1]) }
            if ($l -match '"totalMs":"(\d+)"')         { $phTotal.Add([int]$Matches[1]) }
        } elseif ($l -match '"name":"PhoneRegistration\.Skipped"') {
            $phSkipped++
            if ($l -match '"b2cGetPhoneMs":"(\d+)"')  { $phSkipB2c.Add([int]$Matches[1]) }
        } elseif ($l -match '"name":"PhoneRegistration\.B2CApiCall"') {
            if ($l -match '"b2cGetPhoneMs":"(\d+)"') { $phB2cApiAll.Add([int]$Matches[1]) }
        } elseif ($l -match '"name":"PhoneRegistration\.EEIDApiCall"') {
            if ($l -match '"eeidRegisterMs":"(\d+)"') { $phEeidApiAll.Add([int]$Matches[1]) }
        } elseif ($l -match '"name":"PhoneRegistration\.Failed"') {
            $phFailed++
            if ($l -match '"step":"b2c-get-phone"')   { $phFailedStepB2c++ }
            if ($l -match '"step":"eeid-register"')   { $phFailedStepEeid++ }
            if ($l -match '"errorCode":"([^"]+)"') {
                $ec = $Matches[1]
                $phErrCodes[$ec] = ($phErrCodes[$ec] -as [int]) + 1
            }
        } elseif ($l -match '"name":"Graph\.Throttled"') {
            $phThrottled++
            if ($l -match '"tenantRole":"B2C"') { $phThrottledB2c++ }
            else                                { $phThrottledEeid++ }
        }
    }

    Write-Host ""
    Write-Host ""
    Write-Host "════════════════════════════════════════════" -ForegroundColor Cyan
    Write-Host " PHONE REGISTRATION WORKERS" -ForegroundColor Cyan
    Write-Host "════════════════════════════════════════════" -ForegroundColor Cyan

    Write-Host ""
    Write-Host "=== OUTCOMES ==="
    $phTotal_n = $phSucceeded + $phSkipped + $phFailed
    Write-Host ("  Succeeded (phone registered) : {0,6}" -f $phSucceeded)
    Write-Host ("  Skipped   (no phone in B2C)  : {0,6}" -f $phSkipped)
    Write-Host ("  Failed    (exhausted retries): {0,6}" -f $phFailed)
    Write-Host ("  Total messages processed     : {0,6}" -f $phTotal_n)
    if ($phFailed -gt 0) {
        Write-Host ""
        Write-Host "  Failure breakdown by step:"
        if ($phFailedStepB2c  -gt 0) { Write-Host ("    b2c-get-phone  : {0}" -f $phFailedStepB2c)  -ForegroundColor Yellow }
        if ($phFailedStepEeid -gt 0) { Write-Host ("    eeid-register  : {0}" -f $phFailedStepEeid) -ForegroundColor Yellow }
        if ($phErrCodes.Count -gt 0) {
            Write-Host "  Failure breakdown by error code:"
            foreach ($kv in $phErrCodes.GetEnumerator() | Sort-Object Value -Descending) {
                Write-Host ("    {0,-30}: {1}" -f $kv.Key, $kv.Value) -ForegroundColor Yellow
            }
        }
    }

    Write-Host ""
    Write-Host "=== LATENCY BY PHASE (ms) ==="
    Stats "B2C GET phone   (success)"       ([int[]]$phB2cGet)
    Stats "B2C GET phone   (all API calls)" ([int[]]$phB2cApiAll)
    Stats "EEID POST phone (success)"       ([int[]]$phEeidPost)
    Stats "EEID POST phone (all API calls)" ([int[]]$phEeidApiAll)
    Stats "Total per user  (success)"       ([int[]]$phTotal)
    Stats "B2C GET phone   (skipped)"       ([int[]]$phSkipB2c)

    Write-Host ""
    Write-Host "=== SHARE OF PHONE TIME ==="
    if ($phB2cGet.Count -gt 0 -and $phEeidPost.Count -gt 0) {
        $sumPhB2c  = ($phB2cGet  | Measure-Object -Sum).Sum
        $sumPhEeid = ($phEeidPost | Measure-Object -Sum).Sum
        $sumPhWall = $sumPhB2c + $sumPhEeid
        Write-Host ("  B2C GET phone  : {0,8:N1}s  ({1,3}% of total API time)" -f ($sumPhB2c/1000),  [Math]::Round($sumPhB2c*100/$sumPhWall))
        Write-Host ("  EEID POST phone: {0,8:N1}s  ({1,3}% of total API time)" -f ($sumPhEeid/1000), [Math]::Round($sumPhEeid*100/$sumPhWall))
    }

    Write-Host ""
    Write-Host "=== THROUGHPUT ==="
    if ($phoneTs.Count -ge 2) {
        $pt0 = if ($lastPhoneStartedTs) { $lastPhoneStartedTs } else { ($phoneTs | Sort-Object)[0] }
        $pt1 = ($phoneTs | Sort-Object)[-1]
        $pelapsed = ($pt1 - $pt0).TotalSeconds
        $prunNote = if ($lastPhoneStartedTs) { " (from last PhoneRegistration.Started)" } else { " (from first event)" }
        Write-Host "  Run start   : $pt0$prunNote"
        Write-Host "  Last event  : $pt1"
        Write-Host ("  Elapsed     : {0:N1}s" -f $pelapsed)
        if ($pelapsed -gt 0 -and $phTotal_n -gt 0) {
            # Total throughput = all messages (success + skip + fail)
            Write-Host ("  Msgs/sec    : {0:N2}  (success+skip+fail)" -f ($phTotal_n / $pelapsed))
            Write-Host ("  Msgs/min    : {0:N1}  (success+skip+fail)" -f ($phTotal_n / $pelapsed * 60))
        }
        if ($pelapsed -gt 0 -and $phSucceeded -gt 0) {
            Write-Host ("  Registered/min: {0:N2}" -f ($phSucceeded / $pelapsed * 60))
        }
    }

    Write-Host ""
    Write-Host "=== TAIL LATENCY (phone > 1000ms) ==="
    $slowPhB2c  = ($phoneLines | Where-Object {
        $_ -match '"name":"PhoneRegistration\.Success"' -and
        $_ -match '"b2cGetPhoneMs":"(\d+)"' -and [int]$Matches[1] -gt 1000
    }).Count
    $slowPhEeid = ($phEeidApiAll | Where-Object { $_ -gt 1000 }).Count
    if ($phSucceeded -gt 0) {
        Write-Host ("  Slow B2C GET   (>1s): {0} / {1}  ({2:N1}%)" `
            -f $slowPhB2c,  $phSucceeded, ($slowPhB2c  * 100.0 / $phSucceeded))
    }
    if ($phEeidApiAll.Count -gt 0) {
        Write-Host ("  Slow EEID POST (>1s): {0} / {1}  ({2:N1}%)  [all API calls]" `
            -f $slowPhEeid, $phEeidApiAll.Count, ($slowPhEeid * 100.0 / $phEeidApiAll.Count))
    }

    Write-Host ""
    Write-Host "=== THROTTLES (429) ==="
    Write-Host ("  Graph.Throttled total             : {0}" -f $phThrottled)
    Write-Host ("    B2C  (GET phone - polly retries): {0}" -f $phThrottledB2c)
    Write-Host ("    EEID (POST phone- polly retries): {0}" -f $phThrottledEeid)
    if ($phThrottled -gt 0) {
        Write-Host "  ⚠ Throttles detected — consider increasing ThrottleDelayMs or reducing MaxConcurrency" -ForegroundColor Yellow
    }

    # ── Cross-pipeline summary ─────────────────────────────────────────────────
    if ($userMs.Count -gt 0) {
        Write-Host ""
        Write-Host ""
        Write-Host "════════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host " CROSS-PIPELINE SUMMARY" -ForegroundColor Cyan
        Write-Host "════════════════════════════════════════════" -ForegroundColor Cyan
        Write-Host ""
        Write-Host ("  Users migrated (EEID created)   : {0,6}" -f $userMs.Count)
        Write-Host ("  Phones registered (EEID POST)   : {0,6}" -f $phSucceeded)
        Write-Host ("  Phones skipped  (no B2C phone)  : {0,6}" -f $phSkipped)
        Write-Host ("  Phones failed   (retries exh.)  : {0,6}" -f $phFailed)
        $phoneAttempted = $phSucceeded + $phSkipped + $phFailed
        # Coverage > 100% means the phone queue had stale messages from a previous run
        if ($userMs.Count -gt 0 -and $phoneAttempted -gt 0) {
            $coveragePct = $phoneAttempted * 100.0 / $userMs.Count
            if ($coveragePct -gt 110) {
                Write-Host ("  Phone pipeline coverage         : {0,5:N1}%  ⚠ >100%% — queue had stale messages from a prior run" -f $coveragePct) -ForegroundColor Yellow
                Write-Host "    → Clear per-worker queues: az storage queue clear --name phone-reg-w{1..4} --connection-string UseDevelopmentStorage=true" -ForegroundColor Yellow
            } else {
                Write-Host ("  Phone pipeline coverage         : {0,5:N1}%%" -f $coveragePct)
            }
        }
        if ($userMs.Count -gt 0 -and $phSucceeded -gt 0) {
            Write-Host ("  Users with phone registered     : {0,5:N1}%" -f ($phSucceeded * 100.0 / $userMs.Count))
        }
    }
}

# ═══════════════════════════════════════════════════════════════════════════════
# MARKDOWN REPORT
# ═══════════════════════════════════════════════════════════════════════════════
if ($OutputMarkdown -ne "") {
    $md = [System.Text.StringBuilder]::new()
    $null = $md.AppendLine("# Migration Telemetry Report")
    $null = $md.AppendLine("")
    $null = $md.AppendLine("Generated: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')")
    $null = $md.AppendLine("")
    if ($singleFileMode) {
        $null = $md.AppendLine("**Mode:** single file — ``$resolved``")
    } else {
        $null = $md.AppendLine("**Mode:** multi-worker ($WorkerCount workers)  ")
        $null = $md.AppendLine("**Source:** ``$consoleResolved``  ")
        $null = $md.AppendLine("**Migrate files:** $migrateFound / $WorkerCount ($($migrateLines.Count) lines)  ")
        $null = $md.AppendLine("**Phone files:** $phoneFound / $WorkerCount ($($phoneLines.Count) lines)")
    }

    # ── Migrate Workers ──
    if ($migrateLines.Count -gt 0) {
        $null = $md.AppendLine("")
        $null = $md.AppendLine("## Migrate Workers")
        $null = $md.AppendLine("")
        $null = $md.AppendLine("### Latency by Component (ms)")
        $null = $md.AppendLine("")
        $null = $md.AppendLine("| Metric | n | avg | min | p50 | p90 | p95 | p99 | max |")
        $null = $md.AppendLine("|--------|---|-----|-----|-----|-----|-----|-----|-----|")
        $null = $md.AppendLine((StatsMd "B2C fetch (per batch)" ([int[]]$bB2c)))
        $null = $md.AppendLine((StatsMd "EEID create (pure API)" ([int[]]$userApiMs)))
        $null = $md.AppendLine((StatsMd "EEID create (total op)" ([int[]]$userMs)))
        $null = $md.AppendLine((StatsMd "EEID max (per batch)" ([int[]]$bEeidMax)))
        $null = $md.AppendLine((StatsMd "EEID avg (per batch)" ([int[]]$bEeidAvg)))
        $null = $md.AppendLine((StatsMd "Wall time (b2c+eeid_max)" $wall))

        if ($bB2c.Count -gt 0) {
            $null = $md.AppendLine("")
            $null = $md.AppendLine("### Share of Wall Time")
            $null = $md.AppendLine("")
            $null = $md.AppendLine("| Component | Time (s) | % of Wall |")
            $null = $md.AppendLine("|-----------|----------|-----------|")
            $null = $md.AppendLine(("| B2C fetch | {0:N1} | {1}% |" -f ($sumB2c/1000), [Math]::Round($sumB2c*100/$sumWall)))
            $null = $md.AppendLine(("| EEID create | {0:N1} | {1}% |" -f ($sumEeid/1000), [Math]::Round($sumEeid*100/$sumWall)))
            $null = $md.AppendLine(("| **Total wall** | **{0:N1}** | {1} batches |" -f ($sumWall/1000), $bB2c.Count))
        }

        if ($migrateTs.Count -ge 2) {
            $null = $md.AppendLine("")
            $null = $md.AppendLine("### Throughput")
            $null = $md.AppendLine("")
            $null = $md.AppendLine("| Metric | Value |")
            $null = $md.AppendLine("|--------|-------|")
            $null = $md.AppendLine("| Run start | $t0 |")
            $null = $md.AppendLine("| Last event | $t1 |")
            $null = $md.AppendLine(("| Elapsed | {0:N1}s |" -f $elapsed))
            if ($elapsed -gt 0 -and $userMs.Count -gt 0) {
                $null = $md.AppendLine(("| Users/sec | {0:N2} |" -f ($userMs.Count / $elapsed)))
                $null = $md.AppendLine(("| Users/min | {0:N0} |" -f ($userMs.Count / $elapsed * 60)))
            }
        }

        if ($wall.Count -gt 0) {
            $null = $md.AppendLine("")
            $null = $md.AppendLine("### Theoretical Max (20 users/batch)")
            $null = $md.AppendLine("")
            $null = $md.AppendLine("| Scenario | users/s | users/min |")
            $null = $md.AppendLine("|----------|---------|-----------|")
            $null = $md.AppendLine(("| At avg wall ({0}ms) | {1:N1} | {2:N0} |" -f $avgBatch, (20/$avgBatch*1000), (20/$avgBatch*60000)))
            $null = $md.AppendLine(("| At min wall ({0}ms) | {1:N1} | {2:N0} |" -f $minBatch, (20/$minBatch*1000), (20/$minBatch*60000)))
        }

        $null = $md.AppendLine("")
        $null = $md.AppendLine("### Tail Latency & Throttles")
        $null = $md.AppendLine("")
        if ($userMs.Count -gt 0) {
            $null = $md.AppendLine(("- Slow EEID creates (>1s): $slowCount / $($userMs.Count) ({0:N1}%)" -f ($slowCount * 100.0 / $userMs.Count)))
        }
        $null = $md.AppendLine("- Graph.Throttled B2C: $migrateThrottledB2c")
        $null = $md.AppendLine("- Graph.Throttled EEID: $migrateThrottledEeid")
    }

    # ── Phone Workers ──
    if ($phoneLines.Count -gt 0) {
        $null = $md.AppendLine("")
        $null = $md.AppendLine("## Phone Registration Workers")
        $null = $md.AppendLine("")
        $null = $md.AppendLine("### Outcomes")
        $null = $md.AppendLine("")
        $null = $md.AppendLine("| Outcome | Count |")
        $null = $md.AppendLine("|---------|-------|")
        $null = $md.AppendLine("| Succeeded (phone registered) | $phSucceeded |")
        $null = $md.AppendLine("| Skipped (no phone in B2C) | $phSkipped |")
        $null = $md.AppendLine("| Failed (exhausted retries) | $phFailed |")
        $null = $md.AppendLine("| **Total** | **$phTotal_n** |")

        if ($phFailed -gt 0) {
            $null = $md.AppendLine("")
            $null = $md.AppendLine("#### Failure Breakdown")
            $null = $md.AppendLine("")
            $null = $md.AppendLine("| Category | Count |")
            $null = $md.AppendLine("|----------|-------|")
            if ($phFailedStepB2c -gt 0)  { $null = $md.AppendLine("| Step: b2c-get-phone | $phFailedStepB2c |") }
            if ($phFailedStepEeid -gt 0) { $null = $md.AppendLine("| Step: eeid-register | $phFailedStepEeid |") }
            foreach ($kv in $phErrCodes.GetEnumerator() | Sort-Object Value -Descending) {
                $null = $md.AppendLine("| Error: $($kv.Key) | $($kv.Value) |")
            }
        }

        $null = $md.AppendLine("")
        $null = $md.AppendLine("### Latency by Phase (ms)")
        $null = $md.AppendLine("")
        $null = $md.AppendLine("| Metric | n | avg | min | p50 | p90 | p95 | p99 | max |")
        $null = $md.AppendLine("|--------|---|-----|-----|-----|-----|-----|-----|-----|")
        $null = $md.AppendLine((StatsMd "B2C GET phone (success)" ([int[]]$phB2cGet)))
        $null = $md.AppendLine((StatsMd "B2C GET phone (all API)" ([int[]]$phB2cApiAll)))
        $null = $md.AppendLine((StatsMd "EEID POST phone (success)" ([int[]]$phEeidPost)))
        $null = $md.AppendLine((StatsMd "EEID POST phone (all API)" ([int[]]$phEeidApiAll)))
        $null = $md.AppendLine((StatsMd "Total per user (success)" ([int[]]$phTotal)))
        $null = $md.AppendLine((StatsMd "B2C GET phone (skipped)" ([int[]]$phSkipB2c)))

        if ($phB2cGet.Count -gt 0 -and $phEeidPost.Count -gt 0) {
            $null = $md.AppendLine("")
            $null = $md.AppendLine("### Share of Phone Time")
            $null = $md.AppendLine("")
            $null = $md.AppendLine("| Component | Time (s) | % of API Time |")
            $null = $md.AppendLine("|-----------|----------|---------------|")
            $null = $md.AppendLine(("| B2C GET phone | {0:N1} | {1}% |" -f ($sumPhB2c/1000), [Math]::Round($sumPhB2c*100/$sumPhWall)))
            $null = $md.AppendLine(("| EEID POST phone | {0:N1} | {1}% |" -f ($sumPhEeid/1000), [Math]::Round($sumPhEeid*100/$sumPhWall)))
        }

        if ($phoneTs.Count -ge 2) {
            $null = $md.AppendLine("")
            $null = $md.AppendLine("### Throughput")
            $null = $md.AppendLine("")
            $null = $md.AppendLine("| Metric | Value |")
            $null = $md.AppendLine("|--------|-------|")
            $null = $md.AppendLine("| Run start | $pt0 |")
            $null = $md.AppendLine("| Last event | $pt1 |")
            $null = $md.AppendLine(("| Elapsed | {0:N1}s |" -f $pelapsed))
            if ($pelapsed -gt 0 -and $phTotal_n -gt 0) {
                $null = $md.AppendLine(("| Msgs/sec | {0:N2} |" -f ($phTotal_n / $pelapsed)))
                $null = $md.AppendLine(("| Msgs/min | {0:N1} |" -f ($phTotal_n / $pelapsed * 60)))
            }
            if ($pelapsed -gt 0 -and $phSucceeded -gt 0) {
                $null = $md.AppendLine(("| Registered/min | {0:N2} |" -f ($phSucceeded / $pelapsed * 60)))
            }
        }

        $null = $md.AppendLine("")
        $null = $md.AppendLine("### Tail Latency & Throttles")
        $null = $md.AppendLine("")
        if ($phSucceeded -gt 0) {
            $null = $md.AppendLine(("- Slow B2C GET (>1s): $slowPhB2c / $phSucceeded ({0:N1}%)" -f ($slowPhB2c * 100.0 / $phSucceeded)))
        }
        if ($phEeidApiAll.Count -gt 0) {
            $null = $md.AppendLine(("- Slow EEID POST (>1s): $slowPhEeid / $($phEeidApiAll.Count) ({0:N1}%)" -f ($slowPhEeid * 100.0 / $phEeidApiAll.Count)))
        }
        $null = $md.AppendLine("- Graph.Throttled total: $phThrottled")
        $null = $md.AppendLine("  - B2C: $phThrottledB2c")
        $null = $md.AppendLine("  - EEID: $phThrottledEeid")
    }

    # ── Cross-pipeline ──
    if ($phoneLines.Count -gt 0 -and $userMs.Count -gt 0) {
        $null = $md.AppendLine("")
        $null = $md.AppendLine("## Cross-Pipeline Summary")
        $null = $md.AppendLine("")
        $null = $md.AppendLine("| Metric | Count |")
        $null = $md.AppendLine("|--------|-------|")
        $null = $md.AppendLine("| Users migrated (EEID created) | $($userMs.Count) |")
        $null = $md.AppendLine("| Phones registered | $phSucceeded |")
        $null = $md.AppendLine("| Phones skipped | $phSkipped |")
        $null = $md.AppendLine("| Phones failed | $phFailed |")
        $phoneAttemptedMd = $phSucceeded + $phSkipped + $phFailed
        if ($userMs.Count -gt 0 -and $phoneAttemptedMd -gt 0) {
            $covPct = $phoneAttemptedMd * 100.0 / $userMs.Count
            $null = $md.AppendLine(("| Phone pipeline coverage | {0:N1}% |" -f $covPct))
        }
        if ($userMs.Count -gt 0 -and $phSucceeded -gt 0) {
            $null = $md.AppendLine(("| Users with phone registered | {0:N1}% |" -f ($phSucceeded * 100.0 / $userMs.Count)))
        }
    }

    $null = $md.AppendLine("")
    [System.IO.File]::WriteAllText($OutputMarkdown, $md.ToString())
    Write-Host ""
    Write-Host "Markdown report written to: $OutputMarkdown" -ForegroundColor Green
}
