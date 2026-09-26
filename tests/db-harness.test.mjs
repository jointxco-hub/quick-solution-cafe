import assert from 'node:assert/strict'
import test from 'node:test'
import fs from 'node:fs'

// DB-HARNESS-01 - static guards on the disposable local SQL harness. The harness
// itself is executed with `npm run test:sql`; these tests only stop a later
// edit from making it reach anything that is not a throwaway local cluster.

const read = (path) => fs.readFileSync(new URL(path, import.meta.url), 'utf8').replace(/\r\n/g, '\n')
const runner = read('../supabase/tests/harness/run-local-sql-tests.ps1')
const stub = read('../supabase/tests/harness/00_opps_base_stub.sql')
const code = runner.replace(/<#[\s\S]*?#>/, '').replace(/^\s*#.*$/gm, '')

test('the runner only ever targets a fresh throwaway cluster on a free loopback port', () => {
  assert.match(code, /initdb\b/)
  assert.match(code, /GetTempPath\(\)/, 'data directory lives in the temp folder')
  assert.match(code, /Get-FreePort/)
  assert.match(code, /if \(\$port -eq 5432\) \{ throw/, 'the machine PostgreSQL service port is refused')
  assert.match(code, /'-h', '127\.0\.0\.1'/, 'psql connects to loopback only')
  assert.equal([...code.matchAll(/'-h', '([^']+)'/g)].every((match) => match[1] === '127.0.0.1'), true)
  assert.match(code, /listen_addresses=127\.0\.0\.1/)
  // The target is proven (port, data dir, one database, one role) before anything is loaded.
  const proof = code.indexOf('target is not the fresh throwaway cluster')
  assert.ok(proof > 0 && proof < code.indexOf("00_opps_base_stub.sql'"), 'target proven before the base layer loads')
  assert.match(code, /\[int\]\$parts\[2\] -ne 1 -or \[int\]\$parts\[3\] -ne 1/)
})

test('the runner reaches no remote system, credentials or migration tooling', () => {
  assert.doesNotMatch(code, /\bsupabase\s+(db|link|start|stop|login|migration|push|reset)\b/i)
  assert.doesNotMatch(code, /--linked|db push|db reset|--db-url|\.env\b/i)
  assert.doesNotMatch(code, /Invoke-WebRequest|Invoke-RestMethod|curl |docker/i)
  // Anything in the environment that could steer psql elsewhere is cleared first.
  for (const name of ['PGHOST', 'PGPORT', 'PGDATABASE', 'PGSERVICE', 'DATABASE_URL', 'SUPABASE_DB_URL']) assert.match(code, new RegExp(name))
  assert.match(code, /Remove-Item "Env:\$name"/)
})

test('the throwaway cluster is always stopped and deleted', () => {
  const finallyBlock = code.slice(code.lastIndexOf('finally {'))
  assert.match(finallyBlock, /pg_ctl|\$pgctl/)
  assert.match(finallyBlock, /Remove-Item -Recurse -Force \$dataDir/)
  assert.match(finallyBlock, /-not \$KeepCluster/)
})

test('the migration replay covers every migration except the one documented gap, in filename order', () => {
  const files = fs.readdirSync(new URL('../supabase/migrations/', import.meta.url)).filter((name) => name.endsWith('.sql')).sort()
  // Every Cafe migration, plus the OPPS-owned access migrations, ordered by version timestamp.
  assert.match(code, /Get-ChildItem \(Join-Path \$repo 'supabase\\migrations'\) -Filter \*\.sql/)
  assert.match(code, /foreach \(\$file in \(\$files \| Sort-Object \{ \$_\.Name \}\)\)/)
  const gaps = [...code.matchAll(/^\s+'(\d{14}_[^']+\.sql)' = '([^']+)'/gm)].map((match) => match[1])
  assert.deepEqual(gaps, ['20260913203520_qs_09_1_sa_phone_tracking_normalization.sql'], 'exactly one migration is skipped')
  for (const name of gaps) assert.ok(files.includes(name))
  // The skipped migration really does patch a function only the live database has.
  const skipped = read('../supabase/migrations/20260913203520_qs_09_1_sa_phone_tracking_normalization.sql')
  assert.match(skipped, /pg_get_functiondef/)
  const definers = files.filter((name) => /create (or replace )?function public\.get_quick_solution_tracking\b/i.test(read(`../supabase/migrations/${name}`)))
  assert.deepEqual(definers, [], 'no repository migration defines that function, so it cannot be replayed')
  // The seed data step sits after a migration that exists, before QS-11 needs it.
  const seedAfter = code.match(/\$SeedAfterMigration = '([^']+)'/)[1]
  assert.ok(files.includes(seedAfter))
  assert.ok(files.indexOf(seedAfter) < files.indexOf('20260915150000_qs11_vinyl_stickers_catalog.sql'))
  assert.match(read('../supabase/migrations/20260915150000_qs11_vinyl_stickers_catalog.sql'), /published Quick Solution PVC Banner config/)
})

test('every Cafe SQL test is executed by the runner and is rollback-contained', () => {
  assert.match(code, /-Filter 'cafe_guest_\*\.sql'/)
  const tests = fs.readdirSync(new URL('../supabase/tests/', import.meta.url)).filter((name) => /^cafe_guest_.*\.sql$/.test(name)).sort()
  assert.deepEqual(tests.map((name) => name.slice(0, 14)), ['cafe_guest_01a', 'cafe_guest_01c', 'cafe_guest_01d', 'cafe_guest_01f', 'cafe_guest_01g', 'cafe_guest_01j', 'cafe_guest_01k', 'cafe_guest_01l', 'cafe_guest_01m', 'cafe_guest_01p', 'cafe_guest_01q', 'cafe_guest_01q', 'cafe_guest_01s', 'cafe_guest_01t', 'cafe_guest_01u', 'cafe_guest_01v', 'cafe_guest_01v', 'cafe_guest_01w'])
  for (const name of tests) {
    const sql = read(`../supabase/tests/${name}`).replace(/--[^\n]*/g, '')
    if (/concurrency/.test(name)) {
      // The documented exceptions (CAFE-GUEST-01Q payment race, CAFE-GUEST-01V cancel-versus-payment race): a second session cannot see uncommitted data, so the genuine
      // concurrency test COMMITS its own fixtures, races two sessions, and always deletes what it made. It only ever
      // connects back to the cluster it runs in (loopback, the server's own port); the runner then checks the row counts.
      assert.match(sql, /\\set ON_ERROR_STOP on/, name)
      assert.match(sql, /dblink_connect\('cg01(?:q|v)c_a', v_conn\)/, name)
      assert.match(sql, /host=127\.0\.0\.1 port=%s dbname=%s user=%s', current_setting\('port'\), current_database\(\), current_user/, name)
      assert.equal((sql.match(/host=/g) || []).length, 1, `${name} names exactly one host`)
      assert.match(sql, /select public\._cg01(?:q|v)c_cleanup\(\);[\s\S]*do \$verdict\$/, `${name} always cleans up before it reports a failure`)
      assert.doesNotMatch(sql, /\bbegin;|\brollback;/, name)
      assert.match(read(`../supabase/tests/${name}`), /select '.* passed' as result;/, `${name} ends with a pass row the runner requires`)
      continue
    }
    assert.match(sql, /\\set ON_ERROR_STOP on/, name)
    assert.match(sql, /\bbegin;/, name)
    assert.match(sql, /\brollback;/, name)
    assert.doesNotMatch(sql, /^\s*commit\s*;/im, name)
    assert.match(read(`../supabase/tests/${name}`), /select '.* passed' as result;/, `${name} ends with a pass row the runner requires`)
  }
  assert.match(code, /-match 'passed'/)
  assert.match(code, /tests left no rows behind/)
})

test('the base layer refuses to load anywhere that is not marked disposable and carries verbatim OPPS helper bodies', () => {
  assert.match(stub, /harness\.disposable/)
  assert.match(stub, /raise exception 'DB-HARNESS-01: refusing to load the base stub/)
  assert.match(code, /\$env:PGOPTIONS = '-c harness\.disposable=yes'/)
  // The gate helpers the Cafe admin function calls are present with their real ACLs.
  for (const fn of ['is_app_admin', 'is_opps_staff', 'can_access_tenant', 'current_user_tenant_ids', 'current_user_app_role']) {
    assert.match(stub, new RegExp(`create or replace function public\\.${fn}\\(`))
  }
  assert.match(stub, /revoke all on function public\.can_access_tenant\(uuid\) from public, anon;/)
  assert.match(stub, /revoke all on function public\.is_app_admin\(\) from public, anon;/)
  assert.match(stub, /revoke all on function public\.is_opps_staff\(\) from public, anon, authenticated, service_role;/)
  assert.match(stub, /'jointx\.co@gmail\.com'/, 'the owner-email arm the 01G test relies on')
  // Every table it stubs is documented as partial; nothing is created in the Cafe-owned schema surface beyond OPPS products.
  assert.deepEqual([...stub.matchAll(/^create table ([\w.]+)/gm)].map((match) => match[1]),
    ['auth.users', 'public.tenants', 'public.tenant_memberships', 'public.users', 'public.tenant_capabilities', 'commerce.products', 'public.orders'])
})

test('npm run test:sql runs the harness, and the harness test is part of npm test', () => {
  const scripts = JSON.parse(read('../package.json')).scripts
  assert.match(scripts['test:sql'], /supabase\/tests\/harness\/run-local-sql-tests\.ps1/)
  assert.match(scripts.test, /tests\/db-harness\.test\.mjs/)
  assert.doesNotMatch(scripts['test:sql'], /supabase (db|link|start)/)
})
