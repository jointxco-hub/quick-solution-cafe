<#
DB-HARNESS-01 - disposable local PostgreSQL runner for the Quick Solution Cafe SQL tests.

What it does, every run, from nothing:
  1. initdb a BRAND-NEW PostgreSQL cluster in a temp directory, on a free
     loopback port, trust auth, its own postmaster process. (No Docker, no
     install, no Supabase CLI, no remote project, no existing database.)
  2. proves the target is that throwaway cluster before loading anything.
  3. loads 00_opps_base_stub.sql (the OPPS-owned base layer; see that file).
  4. replays supabase/migrations in filename order, with the one documented
     data step and the one documented gap below.
  5. runs every supabase/tests/cafe_guest_*.sql in its own psql session
     (each is BEGIN ... ROLLBACK and ends with a `... passed` row), then checks
     the rollbacks left nothing behind.
     Two documented exceptions: cafe_guest_01q_counter_payment_concurrency.sql and cafe_guest_01v_cancel_payment_concurrency.sql race two REAL sessions
     (dblink back to this same cluster, loopback only), so it commits its own fixtures and always deletes them.
  6. stops the cluster and deletes the directory, always.

It never reads .env or credentials, never links or pushes, and never connects
to any host but 127.0.0.1 on the port it just chose. The unrelated PostgreSQL
service that may be installed on this machine (port 5432) is refused as a target.

Usage:  powershell -NoProfile -ExecutionPolicy Bypass -File supabase/tests/harness/run-local-sql-tests.ps1 [-KeepCluster] [-Detail] [-PgBin <dir>]
Exit code 0 only if every step passed.

KNOWN LIMITS (also printed at the end of every run):
  * GAP: 20260913203520_qs_09_1_sa_phone_tracking_normalization.sql patches
    public.get_quick_solution_tracking through pg_get_functiondef, but that
    function's body exists only in the live database (QS-09 records "the
    migration boundary while XOS Staging remains the source of the applied
    canonical function bodies"). It cannot be replayed without inventing the
    body, so it is skipped and nothing later depends on it.
  * DATA STEP: supabase/seed.sql is loaded after the last QS-03.1 migration. It
    is not part of the migration history but QS-11 requires its rows.
  * The OPPS-owned base layer is a stub of only what Cafe code touches (helper
    bodies are verbatim OPPS copies). Live drift is invisible here.
  * PostgreSQL 18 locally; the hosted project runs another major version.
#>
param(
  [switch]$KeepCluster,
  [switch]$Detail,
  [string]$PgBin,
  # The OPPS worktree that owns the shared tenant-capability primitive
  # (public.has_tenant_capability, CAFE-ACCESS-01/02). Only READ from: its
  # supabase/migrations/cafe_access_*.sql are merged into the replay by version
  # timestamp, and its supabase/tests/cafe_access_*.sql are run. If it is absent the
  # access layer is reported as SKIP (never silently passed).
  [string]$OppsAccessRepo
)

$ErrorActionPreference = 'Continue'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..\..\..')).Path
if (-not $OppsAccessRepo) { $OppsAccessRepo = Join-Path (Split-Path $repo) 'opps-xos-2-7c-test-order-hygiene' }

# The one migration that cannot be replayed, and why (see header).
$UnreplayableMigrations = @{
  '20260913203520_qs_09_1_sa_phone_tracking_normalization.sql' = 'patches a function whose body exists only in the live database'
}
# supabase/seed.sql is applied right after this migration (QS-11 needs its rows).
$SeedAfterMigration = '20260913164400_qs_03_1_upload_token_crypto_fix.sql'

function Find-PgBin {
  if ($PgBin) { return $PgBin }
  $roots = @('C:\Program Files\PostgreSQL', 'C:\Program Files (x86)\PostgreSQL')
  foreach ($root in $roots) {
    if (Test-Path $root) {
      $hit = Get-ChildItem $root -Directory | Sort-Object { [int]($_.Name -replace '\D', '0') } -Descending |
        Where-Object { Test-Path (Join-Path $_.FullName 'bin\initdb.exe') } | Select-Object -First 1
      if ($hit) { return (Join-Path $hit.FullName 'bin') }
    }
  }
  $onPath = Get-Command initdb -ErrorAction SilentlyContinue
  if ($onPath) { return (Split-Path $onPath.Source) }
  throw 'DB-HARNESS-01: no local PostgreSQL binaries found (need initdb, postgres, psql). Pass -PgBin <dir>.'
}

function Get-FreePort {
  $listener = New-Object System.Net.Sockets.TcpListener([System.Net.IPAddress]::Loopback, 0)
  $listener.Start()
  $port = $listener.LocalEndpoint.Port
  $listener.Stop()
  return $port
}

$bin = Find-PgBin
$initdb = Join-Path $bin 'initdb.exe'
$postgres = Join-Path $bin 'postgres.exe'
$pgctl = Join-Path $bin 'pg_ctl.exe'
$psql = Join-Path $bin 'psql.exe'
foreach ($exe in @($initdb, $postgres, $pgctl, $psql)) { if (-not (Test-Path $exe)) { throw "DB-HARNESS-01: missing $exe" } }

# Nothing in the environment may steer psql anywhere else.
foreach ($name in 'PGHOST', 'PGPORT', 'PGDATABASE', 'PGUSER', 'PGSERVICE', 'PGPASSFILE', 'PGSERVICEFILE', 'DATABASE_URL', 'SUPABASE_DB_URL') {
  Remove-Item "Env:$name" -ErrorAction SilentlyContinue
}
$env:PGOPTIONS = '-c harness.disposable=yes'
$env:PGPASSWORD = ''

$port = Get-FreePort
if ($port -eq 5432) { throw 'DB-HARNESS-01: refusing port 5432 (the machine PostgreSQL service).' }
$dataDir = Join-Path ([System.IO.Path]::GetTempPath()) ("qs-harness-pg-" + [guid]::NewGuid().ToString('N').Substring(0, 12))
$log = Join-Path ([System.IO.Path]::GetTempPath()) ("qs-harness-pg-" + [guid]::NewGuid().ToString('N').Substring(0, 12) + '.log')
$conn = @('-X', '-h', '127.0.0.1', '-p', "$port", '-U', 'postgres', '-v', 'ON_ERROR_STOP=1')

$results = New-Object System.Collections.ArrayList
function Add-Result($group, $name, $status, $detail) { [void]$results.Add([pscustomobject]@{ Group = $group; Name = $name; Status = $status; Detail = $detail }) }

function Invoke-Psql([string]$db, [string[]]$more) {
  $text = & $psql @conn -d $db @more 2>&1 | Out-String
  return [pscustomobject]@{ Code = $LASTEXITCODE; Text = $text }
}
function First-Error([string]$text) {
  $lines = $text -split "`r?`n"
  $hit = $lines | Where-Object { $_ -match 'ERROR:' } | Select-Object -First 1
  if ($hit) { return ($hit -replace '^.*ERROR:\s*', '').Trim() }
  return (($lines | Where-Object { $_.Trim() } | Select-Object -Last 1))
}

$server = $null
$exit = 1
try {
  Write-Host "== DB-HARNESS-01: disposable local PostgreSQL harness =="
  Write-Host "PostgreSQL binaries : $bin"
  Write-Host "Throwaway data dir  : $dataDir"
  Write-Host "Loopback port       : $port"

  $init = & $initdb -D $dataDir -U postgres --auth=trust -E UTF8 --locale=C 2>&1 | Out-String
  if ($LASTEXITCODE -ne 0) { throw "initdb failed: $init" }

  # Windows PowerShell 5.1 does not quote array arguments for Start-Process, and
  # the temp path may contain spaces, so the argument string is built by hand.
  $serverArgs = "-D `"$dataDir`" -p $port -c listen_addresses=127.0.0.1 -c fsync=off -c synchronous_commit=off"
  $server = Start-Process -FilePath $postgres -ArgumentList $serverArgs -PassThru -WindowStyle Hidden -RedirectStandardError $log
  $ready = $false
  for ($i = 0; $i -lt 60; $i++) {
    Start-Sleep -Milliseconds 500
    if ($server.HasExited) { throw "postgres exited early; see $log" }
    & (Join-Path $bin 'pg_isready.exe') -h 127.0.0.1 -p $port -U postgres -q
    if ($LASTEXITCODE -eq 0) { $ready = $true; break }
  }
  if (-not $ready) { throw 'postgres did not become ready' }

  # ── prove the target is the throwaway cluster before anything is loaded ──
  $probe = Invoke-Psql 'postgres' @('-Atc', "select inet_server_port() || '|' || current_setting('data_directory') || '|' || (select count(*) from pg_database where not datistemplate) || '|' || (select count(*) from pg_roles where rolname !~ '^pg_')")
  if ($probe.Code -ne 0) { throw "probe failed: $($probe.Text)" }
  $parts = $probe.Text.Trim().Split('|')
  $reportedDir = ($parts[1] -replace '/', '\').TrimEnd('\')
  $expectedDir = $dataDir.TrimEnd('\')
  # Compare the resolved 8.3/long forms of the temp path too.
  $sameDir = ($reportedDir -ieq $expectedDir) -or ((Get-Item $reportedDir).FullName -ieq (Get-Item $expectedDir).FullName)
  if ([int]$parts[0] -ne $port -or -not $sameDir -or [int]$parts[2] -ne 1 -or [int]$parts[3] -ne 1) {
    throw "DB-HARNESS-01: target is not the fresh throwaway cluster (port/dir/db count/role count = $($probe.Text.Trim())); aborting before loading anything."
  }
  Write-Host "Target verified     : fresh cluster (1 database, 1 role) at the throwaway dir on port $port"
  Add-Result 'harness' 'target is the throwaway cluster' 'PASS' "port $port, dir $dataDir"

  $dbName = 'qs_harness'
  $r = Invoke-Psql 'postgres' @('-q', '-c', "create database $dbName")
  if ($r.Code -ne 0) { throw "create database failed: $($r.Text)" }

  # ── base layer ────────────────────────────────────────────────────────────
  $r = Invoke-Psql $dbName @('-q', '-f', (Join-Path $PSScriptRoot '00_opps_base_stub.sql'))
  if ($r.Code -ne 0) { Add-Result 'base' '00_opps_base_stub.sql' 'FAIL' (First-Error $r.Text); throw 'base stub failed' }
  Add-Result 'base' '00_opps_base_stub.sql' 'PASS' 'OPPS-owned base layer loaded'

  # ── migration replay ──────────────────────────────────────────────────────
  $migrationFailed = $false
  # The Cafe history, plus the OPPS-owned access migrations (if that worktree is present),
  # ordered by version timestamp exactly as a shared database would apply them.
  $files = @(Get-ChildItem (Join-Path $repo 'supabase\migrations') -Filter *.sql | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Path = $_.FullName; Origin = '' } })
  $oppsAccessMigrations = Join-Path $OppsAccessRepo 'supabase\migrations'
  $oppsAccessTests = Join-Path $OppsAccessRepo 'supabase\tests'
  $accessPresent = (Test-Path $oppsAccessMigrations) -and (Test-Path $oppsAccessTests)
  if ($accessPresent) {
    $accessFiles = @(Get-ChildItem $oppsAccessMigrations -Filter 'cafe_access_*.sql' -ErrorAction SilentlyContinue)
    $accessFiles += @(Get-ChildItem $oppsAccessMigrations -Filter '*_cafe_access_*.sql' -ErrorAction SilentlyContinue)
    $files += @($accessFiles | Sort-Object Name -Unique | ForEach-Object { [pscustomobject]@{ Name = $_.Name; Path = $_.FullName; Origin = 'OPPS access layer' } })
  } else {
    Add-Result 'access' 'OPPS access layer (public.has_tenant_capability)' 'SKIP' "OPPS worktree not found at $OppsAccessRepo; pass -OppsAccessRepo <dir> to run the CAFE-ACCESS migrations and tests"
  }
  foreach ($file in ($files | Sort-Object { $_.Name })) {
    if ($UnreplayableMigrations.ContainsKey($file.Name)) {
      Add-Result 'migration' $file.Name 'SKIP' $UnreplayableMigrations[$file.Name]
      continue
    }
    # A Cafe migration that calls the OPPS-owned primitive cannot apply without the access layer.
    if (-not $accessPresent -and $file.Origin -eq '' -and (Select-String -Path $file.Path -Pattern 'has_tenant_capability' -Quiet)) {
      Add-Result 'migration' $file.Name 'SKIP' 'needs the OPPS access layer (public.has_tenant_capability), which is not present'
      continue
    }
    $r = Invoke-Psql $dbName @('-q', '-f', $file.Path)
    if ($r.Code -ne 0) {
      Add-Result 'migration' $file.Name 'FAIL' (First-Error $r.Text)
      $migrationFailed = $true
      break
    }
    Add-Result 'migration' $file.Name 'PASS' $file.Origin
    if ($file.Name -eq $SeedAfterMigration) {
      $s = Invoke-Psql $dbName @('-q', '-f', (Join-Path $repo 'supabase\seed.sql'))
      if ($s.Code -ne 0) { Add-Result 'data' 'supabase/seed.sql' 'FAIL' (First-Error $s.Text); $migrationFailed = $true; break }
      Add-Result 'data' 'supabase/seed.sql' 'PASS' 'loaded after the last QS-03.1 migration'
    }
  }

  # ── SQL tests (only if the whole history applied) ─────────────────────────
  $baseline = $null
  if (-not $migrationFailed) {
    $count = 'select (select count(*) from public.tenants) || ''|'' || (select count(*) from commerce.products) || ''|'' || (select count(*) from commerce.service_product_configs) || ''|'' || (select count(*) from commerce.service_orders) || ''|'' || (select count(*) from auth.users) || ''|'' || (select count(*) from public.users)'
    $baseline = (Invoke-Psql $dbName @('-Atc', $count)).Text.Trim()
    $tests = @(Get-ChildItem (Join-Path $repo 'supabase\tests') -Filter 'cafe_guest_*.sql' | Sort-Object Name | ForEach-Object { [pscustomobject]@{ Name = $_.Name; FullName = $_.FullName; Origin = '' } })
    if ($accessPresent) {
      $tests += @(Get-ChildItem $oppsAccessTests -Filter 'cafe_access_*.sql' | Sort-Object Name | ForEach-Object { [pscustomobject]@{ Name = $_.Name; FullName = $_.FullName; Origin = 'OPPS access layer' } })
    }
    foreach ($test in $tests) {
      if (-not $accessPresent -and $test.Origin -eq '' -and (Select-String -Path $test.FullName -Pattern 'has_tenant_capability' -Quiet)) {
        Add-Result 'sql-test' $test.Name 'SKIP' 'needs the OPPS access layer (public.has_tenant_capability), which is not present'
        continue
      }
      $r = Invoke-Psql $dbName @('-f', $test.FullName)
      $passed = ($r.Code -eq 0) -and ($r.Text -match 'passed')
      if ($passed) { Add-Result 'sql-test' $test.Name 'PASS' $test.Origin } else {
        Add-Result 'sql-test' $test.Name 'FAIL' (First-Error $r.Text)
        # -Detail: the whole psql output of a failed test (ERROR, DETAIL, CONTEXT), for debugging.
        if ($Detail) { Write-Host "---- full output of failed test $($test.Name) ----"; Write-Host $r.Text; Write-Host '----' }
      }
    }
    $after = (Invoke-Psql $dbName @('-Atc', $count)).Text.Trim()
    if ($after -eq $baseline) { Add-Result 'rollback' 'tests left no rows behind' 'PASS' "row counts unchanged ($baseline)" }
    else { Add-Result 'rollback' 'tests left no rows behind' 'FAIL' "before $baseline, after $after" }
  }
}
catch {
  Add-Result 'harness' 'run' 'FAIL' $_.Exception.Message
}
finally {
  if ($server -and -not $server.HasExited) {
    & $pgctl stop -D $dataDir -m immediate -s 2>&1 | Out-Null
    Start-Sleep -Milliseconds 500
    if (-not $server.HasExited) { Stop-Process -Id $server.Id -Force -ErrorAction SilentlyContinue }
  }
  if (-not $KeepCluster) {
    Start-Sleep -Milliseconds 500
    Remove-Item -Recurse -Force $dataDir -ErrorAction SilentlyContinue
    Remove-Item -Force $log -ErrorAction SilentlyContinue
  } else { Write-Host "Cluster kept at $dataDir (stopped)." }
}

Write-Host ''
Write-Host '== Results =='
foreach ($group in 'harness', 'base', 'access', 'migration', 'data', 'sql-test', 'rollback') {
  $rows = @($results | Where-Object { $_.Group -eq $group })
  if ($rows.Count -eq 0) { continue }
  foreach ($row in $rows) {
    $tail = ''
    if ($row.Detail) { $tail = "  - $($row.Detail)" }
    Write-Host ("[{0,-4}] {1,-9} {2}{3}" -f $row.Status, $row.Group, $row.Name, $tail)
  }
}
$failed = @($results | Where-Object { $_.Status -eq 'FAIL' }).Count
$passedTests = @($results | Where-Object { $_.Group -eq 'sql-test' -and $_.Status -eq 'PASS' }).Count
$skipped = @($results | Where-Object { $_.Status -eq 'SKIP' }).Count
Write-Host ''
Write-Host "SQL tests passed: $passedTests | failures: $failed | skipped migrations (documented gap): $skipped"
Write-Host 'Known limits: qs_09_1 skipped (live-only function body); seed.sql placed after the last QS-03.1 migration; OPPS base layer is a stub; local PostgreSQL major differs from hosted.'
if ($failed -eq 0) { $exit = 0 }
exit $exit
