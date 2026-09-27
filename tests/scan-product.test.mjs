import assert from 'node:assert/strict'
import test from 'node:test'
import fs from 'node:fs'
import { products } from '../src/data/products.js'
import { buildPricingDefinition } from '../src/lib/pricingDefinition.js'
import { validatePerUnitDefinition } from '../src/lib/perUnitPricing.js'
import { calculateProductPrice, getDefaultConfig } from '../src/lib/pricing.js'
import { resolveCounterProduct, isCounterProduct, resolveCounterAction, resolveCounterGroup } from '../src/lib/counterCatalogue.js'
import { resolveShopCategory, resolveStartingPriceEligibility, resolveProductPriceCue, resolveHubAvailability } from '../src/lib/productContent.js'

// CAFE-GUEST-01H / 01K - Scan, the first PER_UNIT product.
//
// 01H created it structurally (not live, unpriced: no verified price existed). 01K
// finalizes it with the confirmed business decision: R5 per scanned page, minimum 1,
// maximum 300 pages per order, live, still counter-only. The SQL counterpart,
// supabase/tests/cafe_guest_01k_scan_final.sql, runs on the local harness
// (npm run test:sql) against the seeded row and re-applies the 01K migration.

const read = (path) => fs.readFileSync(new URL(path, import.meta.url), 'utf8').replace(/\r\n/g, '\n')
const SEED_MIGRATION = '../supabase/migrations/20260926150000_cafe_guest_01h_scan_product.sql'
const FINAL_MIGRATION = '../supabase/migrations/20260926180000_cafe_guest_01k_scan_final.sql'
const finalSql = read(FINAL_MIGRATION)
const finalCode = finalSql.replace(/--[^\n]*/g, '')
const scan = products.find((product) => product.id === 'scan')
const a4 = products.find((product) => product.id === 'a4-lamination')
const a3 = products.find((product) => product.id === 'a3-lamination')

const NINE = ['pvc-banner', 'vinyl-stickers', 'a4-print', 'business-cards', 'printed-tshirt', 'media-services', 'flags', 'gazebos', 'photo-session']
const APPROVED = { strategy: 'PER_UNIT', unitPrice: 5, minUnits: 1, maxUnits: 300 }
const PENDING = { strategy: 'PER_UNIT', unitPrice: 0, minUnits: 1, maxUnits: 0 }
const COUNTER_ONLY = { storefront: false, guided: false, pos: true, quote: false, advanced: false }
const clone = (value) => JSON.parse(JSON.stringify(value))

const deepKeys = (value, keys = new Set()) => {
  if (Array.isArray(value)) value.forEach((item) => deepKeys(item, keys))
  else if (value && typeof value === 'object') for (const [key, child] of Object.entries(value)) { keys.add(key); deepKeys(child, keys) }
  return keys
}

// ── identity ───────────────────────────────────────────────────────────
test('Scan exists exactly once, with a deliberate key, name and category', () => {
  assert.equal(products.filter((product) => product.id === 'scan').length, 1)
  assert.equal(products.length, 12, 'the nine original products plus Scan, A4 Lamination and A3 Lamination')
  assert.equal(products[9], scan)
  assert.equal(scan.name, 'Document Scanning')
  assert.equal(scan.shortName, 'Scanning')
  // 'Quick Print' is already mapped everywhere: shop bucket, counter group, no new category.
  assert.equal(scan.category, 'Quick Print')
  assert.equal(resolveShopCategory(scan), 'Print & Documents')
  assert.equal(resolveCounterGroup(scan), 'Quick Services')
  for (const product of products.filter((item) => !/^a[34]-lamination$/.test(item.id))) assert.doesNotMatch(`${product.id} ${product.name}`, /lamin/i)
})

// ── the approved PER_UNIT definition ───────────────────────────────────
test('Scan is R5 per scanned page, minimum 1, maximum 300, exactly the four PER_UNIT keys', () => {
  assert.deepEqual(scan.pricing, APPROVED)
  assert.deepEqual(Object.keys(scan.pricing), ['strategy', 'unitPrice', 'minUnits', 'maxUnits'])
  assert.equal(validatePerUnitDefinition(scan.pricing).ok, true)
  assert.doesNotMatch(JSON.stringify(scan), /setupFee|minimumCharge|tier|discount|variant|surcharge|multiplier|fee|option/i)
  assert.equal(scan.pricingVersion, '2026-09-qsc-18')
})

test('client pricing: 1 page -> R5, 4 -> R20, 100 -> R500, 300 -> R1500', () => {
  for (const [units, total] of [[1, 5], [4, 20], [100, 500], [300, 1500]]) {
    for (const value of [units, String(units)]) {
      const result = calculateProductPrice(scan, { units: value })
      assert.equal(result.total, total, `${value} pages`)
      assert.deepEqual(result.metrics, { units, unitPrice: 5 })
    }
  }
  assert.equal(calculateProductPrice(scan, { units: 4 }).summary, '4 × 5.00')
})

test('invalid page counts are rejected and never yield a usable total; quantity cannot substitute for units', () => {
  for (const units of [undefined, null, '', 'abc', 0, -1, 2.5, 0.5, 301, '301', '007', '1e1', ' 3', '+3', true, [3]]) {
    const result = calculateProductPrice(scan, units === undefined ? {} : { units })
    assert.equal(result.total, 0, String(units))
    assert.equal(result.metrics.invalid, true, String(units))
  }
  assert.equal(calculateProductPrice(scan, { quantity: 3 }).total, 0, 'quantity is not units')
  assert.equal(calculateProductPrice(scan, { quantity: 3, units: 2 }).total, 10, 'units is used, quantity ignored')
})

// ── live, but counter-only ─────────────────────────────────────────────
test('Scan is live with approved pricing, yet never on the storefront', () => {
  assert.equal(scan.active, true, 'live, like every other seeded product with an approved price')
  assert.equal(scan.popular, false)
  assert.doesNotThrow(() => buildPricingDefinition(scan), 'the admin save accepts the approved pricing')
  const storefrontRule = (product) => product.active !== false && product.channels?.storefront !== false
  assert.equal(storefrontRule(scan), false)
  // Only original products can be on the storefront: Scan and the counter-only Lamination products never are.
  assert.deepEqual(products.filter(storefrontRule).map((product) => product.id).sort(), NINE.filter((id) => products.find((product) => product.id === id).active !== false).sort())
  assert.match(read('../src/App.jsx'), /catalog\.filter\(\(product\) => product\.active !== false && product\.channels\?\.storefront !== false\)/)
  assert.deepEqual(resolveStartingPriceEligibility(scan), { mode: 'none' })
  assert.equal(resolveProductPriceCue(scan), null)
  assert.equal(scan.productPage, undefined)
})

test('channel decisions are unchanged and pinned: counter-only, every customer-facing channel off', () => {
  assert.deepEqual(scan.channels, COUNTER_ONLY)
  assert.equal(scan.guidedJourneyId, undefined)
  assert.equal(isCounterProduct(scan), true, 'staff may start a Scan for a walk-in customer')
  assert.deepEqual(resolveHubAvailability(scan, { onGuided: () => {}, onConfigure: () => {} }), { hasGuided: false, hasAdvanced: false })
})

test('counter action is order and group is Quick Services through the generic rules, with no Scan branch', () => {
  assert.equal(resolveCounterAction(scan), 'order')
  assert.deepEqual({ ...resolveCounterProduct(scan), product: undefined }, { product: undefined, visible: true, action: 'order', group: 'Quick Services' })
  const code = (file) => read(file).replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/[^\n]*/g, '')
  for (const file of ['../src/lib/counterCatalogue.js', '../src/lib/pricing.js', '../src/lib/perUnitPricing.js', '../src/lib/pricingDefinition.js', '../src/lib/counterPrintConfig.js', '../src/App.jsx']) {
    assert.doesNotMatch(code(file), /\bscan\b|lamin/i, file)
  }
})

// ── unit meaning and runtime configuration ─────────────────────────────
test('one unit is one scanned page, counted by { units } and never by quantity', () => {
  assert.equal(scan.fields.length, 1)
  const [field] = scan.fields
  assert.equal(field.id, 'units')
  assert.equal(field.type, 'number')
  assert.equal(field.required, true)
  assert.equal(field.min, scan.pricing.minUnits)
  assert.equal(field.step, 1, 'whole numbers only')
  assert.equal(field.label, 'How many pages need scanning?')
  assert.equal(field.suffix, 'pages')
  assert.match(field.help, /one side of a sheet is one page/i)
  // Nothing that would go stale when an admin edits the price or maximum later.
  assert.equal('max' in field, false)
  assert.equal('default' in field, false)
  assert.equal(getDefaultConfig(scan, {}).units, '')
  assert.equal('quantity' in getDefaultConfig(scan, {}), false)
  assert.equal(deepKeys(scan).has('quantity'), false)
  assert.doesNotMatch(JSON.stringify(scan), /quantity/i)
  assert.doesNotMatch(finalCode, /quantity/i)
  // Pages, not sheets: Lamination counts sheets.
  assert.doesNotMatch(`${scan.description} ${scan.plainDescription} ${field.label} ${field.shortLabel} ${field.suffix}`, /\bsheets?\b/i)
})

test('Scan needs no upload: it has no file field and no file requirement', () => {
  assert.equal(scan.fields.some((field) => field.type === 'file' || field.id === 'file'), false)
  assert.doesNotMatch(JSON.stringify(scan), /upload|fileName|artwork/i)
})

test('the customer pricing mirror exposes only the four allowed pricing fields and nothing private', () => {
  assert.deepEqual(Object.keys(scan.pricing).sort(), ['maxUnits', 'minUnits', 'strategy', 'unitPrice'])
  assert.doesNotMatch(JSON.stringify(scan), /supplier|margin|referencePrice|sourceUrl|sourceName|pricingDefinition|pricing_definition|vat/i)
  assert.equal('pricingDefinition' in scan, false)
})

// ── admin: editable later, independently, with no code change ──────────
test('admin round-trips Scan, edits its price and maximum independently of Lamination, and still refuses invalid values', () => {
  assert.deepEqual(buildPricingDefinition(scan), APPROVED)
  assert.deepEqual(JSON.parse(JSON.stringify(buildPricingDefinition(scan))), APPROVED)

  const lamBefore = clone([a4, a3])
  const edited = { ...clone(scan), pricing: { ...scan.pricing, unitPrice: 6.5, maxUnits: 250 } }
  assert.deepEqual(buildPricingDefinition(edited), { strategy: 'PER_UNIT', unitPrice: 6.5, minUnits: 1, maxUnits: 250 })
  assert.equal(calculateProductPrice(edited, { units: 4 }).total, 26)
  assert.equal(calculateProductPrice(edited, { units: 251 }).total, 0, 'the edited maximum applies')
  assert.deepEqual(clone([a4, a3]), lamBefore, 'editing Scan did not mutate A4 or A3')
  assert.equal(calculateProductPrice(a4, { units: 4 }).total, 60)
  assert.equal(calculateProductPrice(a3, { units: 4 }).total, 120)

  // The other way round: editing a Lamination product leaves Scan alone.
  const scanBefore = clone(scan)
  const editedA4 = { ...clone(a4), pricing: { ...a4.pricing, unitPrice: 20 } }
  assert.equal(buildPricingDefinition(editedA4).unitPrice, 20)
  assert.deepEqual(clone(scan), scanBefore)

  assert.throws(() => buildPricingDefinition({ ...clone(scan), pricing: { ...scan.pricing, unitPrice: 0 } }), /unitPrice must be greater than 0/)
  assert.throws(() => buildPricingDefinition({ ...clone(scan), pricing: { ...scan.pricing, unitPrice: 5.005 } }), /whole cents/)
  assert.throws(() => buildPricingDefinition({ ...clone(scan), pricing: { ...scan.pricing, maxUnits: 0 } }), /maxUnits must be at least minUnits/)
  // The generic editor already renders every numeric pricing key.
  assert.deepEqual(Object.entries(scan.pricing).filter(([key, value]) => key !== 'strategy' && typeof value === 'number').map(([key]) => key), ['unitPrice', 'minUnits', 'maxUnits'])
})

test('no code path knows Scan: a future price or maximum change needs Admin only', () => {
  const walk = (dir, out = []) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const path = new URL(`${entry.name}${entry.isDirectory() ? '/' : ''}`, dir)
      if (entry.isDirectory()) walk(path, out)
      else if (/\.(jsx?|css)$/.test(entry.name)) out.push({ name: entry.name, text: fs.readFileSync(path, 'utf8') })
    }
    return out
  }
  const stripped = (text) => text.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/[^\n]*/g, '')
  const mentions = walk(new URL('../src/', import.meta.url)).filter((file) => /['"]scan['"]/.test(stripped(file.text))).map((file) => file.name)
  assert.deepEqual(mentions.sort(), ['counterSubmissionReadiness.js', 'products.js'], 'only the seeded data and the deliberate first-write rollout list (CAFE-GUEST-01O) name the Scan product')
})

// ── nothing else moved ─────────────────────────────────────────────────
test('the nine original products and both Lamination products are unchanged', () => {
  assert.deepEqual(clone(products.slice(0, 9)), JSON.parse(read('./fixtures/nine-products-before-scan.json')))
  assert.deepEqual(products.slice(0, 9).map((product) => product.id), NINE)
  assert.deepEqual(clone([a4, a3]), JSON.parse(read('./fixtures/lamination-products-before-scan-final.json')), 'A4 and A3 Lamination are exactly as 01J left them')
  assert.deepEqual(a4.pricing, { strategy: 'PER_UNIT', unitPrice: 15, minUnits: 1, maxUnits: 100 })
  assert.deepEqual(a3.pricing, { strategy: 'PER_UNIT', unitPrice: 30, minUnits: 1, maxUnits: 100 })
  const golden = JSON.parse(read('./fixtures/pricing-golden-before-per-unit.json'))
  assert.deepEqual(Object.keys(golden).sort(), [...NINE].sort())
  const a4Print = products.find((product) => product.id === 'a4-print')
  assert.equal(a4Print.pricing.strategy, 'PER_PAGE')
  assert.doesNotMatch(read('../src/lib/counterPrintConfig.js'), /scan|units|PER_UNIT|lamin/i)
})

// ── the migrations ─────────────────────────────────────────────────────
test('the 01H migration is left as the historical initial seed, and 01H plus 01K gives exactly the client product', () => {
  const seedSql = read(SEED_MIGRATION)
  const seedCustomer = JSON.parse(seedSql.match(/\$customer\$([\s\S]*?)\$customer\$/)[1])
  const seedDefinition = JSON.parse(seedSql.match(/\$definition\$([\s\S]*?)\$definition\$/)[1])
  assert.deepEqual(seedDefinition, PENDING, 'not rewritten: 01H still seeds the pending placeholder')
  assert.deepEqual(seedCustomer.pricing, PENDING)
  assert.equal(seedCustomer.active, false)
  assert.match(seedSql, /'2026-09-qsc-15',/)
  assert.match(seedSql, /'ZAR',\s*'unavailable',\s*'draft',/)

  // What 01K sets, applied to what 01H seeded, is exactly the client product (minus pricingVersion).
  const approved = JSON.parse(finalCode.match(/pricing_definition = '(\{[^']*\})'::jsonb/)[1])
  assert.deepEqual(approved, APPROVED)
  const { pricingVersion, ...clientDefinition } = clone(scan)
  const upgraded = { ...seedCustomer, active: true, pricing: approved }
  assert.deepEqual(upgraded, clientDefinition, 'customer_definition after 01K equals the client product')
  assert.equal(pricingVersion, '2026-09-qsc-18')
  assert.match(finalCode, /pricing_version = '2026-09-qsc-18'/)
  // Live: the customer_definition is switched active, and the config is published.
  assert.match(finalCode, /'\{active\}', 'true'::jsonb, true/)
  assert.match(finalCode, /set status = 'published',\s*pricing_definition = /)
})

test('the 01K migration updates only Scan, only while it is still exactly as 01H seeded it, and republishes only that row', () => {
  const bare = finalCode.replace(/'(?:[^']|'')*'/g, "''")
  // Guard: pristine 01H state only, so no later admin edit (price, maximum, offline) can be overwritten.
  assert.match(finalCode, /c\.source_key = 'scan'\s+and c\.pricing_version = '2026-09-qsc-15'\s+and c\.status = 'draft'\s+and c\.pricing_definition = '\{"strategy": "PER_UNIT", "unitPrice": 0, "minUnits": 1, "maxUnits": 0\}'::jsonb/)
  // The product row is updated in the same statement, only for the row just finalized.
  assert.match(finalCode, /with finalized as \(\s*update commerce\.service_product_configs c[\s\S]*returning c\.product_id\s*\)\s*update commerce\.products p\s*set status = 'published',\s*availability = 'available',\s*updated_at = now\(\)\s*from finalized f\s*where p\.id = f\.product_id;/)
  assert.deepEqual([...bare.matchAll(/\bupdate\s+([\w.]+)/gi)].map((match) => match[1]), ['commerce.service_product_configs', 'commerce.products'])
  assert.doesNotMatch(bare, /\b(insert|delete|alter|drop|grant|revoke|truncate)\b/i)
  assert.doesNotMatch(bare, /\bcreate\s+(or replace\s+)?(function|table|trigger|policy|index|view)\b/i)
  assert.doesNotMatch(bare, /^\s*(begin|commit|rollback)\s*;/im, 'no BEGIN/COMMIT, so the SQL test can re-apply it inside its own transaction')
  // The channels and everything else in customer_definition are untouched: only pricing and active are set.
  assert.doesNotMatch(finalCode, /channels/i)
  assert.deepEqual([...finalCode.matchAll(/'(\{\w+\})'/g)].map((match) => match[1]).sort(), ['{active}', '{pricing}'])
  // Only the Scan config columns it should write.
  const configUpdate = finalCode.match(/update commerce\.service_product_configs c[\s\S]*?from public\.tenants t/)[0]
  assert.deepEqual([...configUpdate.matchAll(/^\s*(?:set\s+)?(\w+) = /gm)].map((match) => match[1]), ['status', 'pricing_definition', 'customer_definition', 'pricing_version', 'updated_at'])
  assert.doesNotMatch(finalCode, /a[34]-lamination|'lamination'/, 'Lamination is untouched')
  // The approved definition is validated by the one shared PER_UNIT rule when the migration runs.
  assert.match(finalCode, /perform commerce\._qs_validate_per_unit_definition\('\{"strategy": "PER_UNIT", "unitPrice": 5, "minUnits": 1, "maxUnits": 300\}'::jsonb\);/)
  assert.match(finalSql, /to_regprocedure\('commerce\._qs_validate_per_unit_definition\(jsonb\)'\) is null/)
})

test('the forward migration comes after 01H (Scan) and 01J (Lamination)', () => {
  const files = fs.readdirSync(new URL('../supabase/migrations/', import.meta.url)).filter((name) => name.endsWith('.sql')).sort()
  assert.ok(files.includes('20260926180000_cafe_guest_01k_scan_final.sql'), 'still present; the counter catalogue (01L) comes after it')
  assert.ok(files.indexOf('20260926150000_cafe_guest_01h_scan_product.sql') < files.indexOf('20260926170000_cafe_guest_01j_lamination_a4_a3.sql'))
  assert.ok(files.indexOf('20260926170000_cafe_guest_01j_lamination_a4_a3.sql') < files.length - 1)
})

test('the SQL contract test is rollback-contained, re-applies the migration in-transaction, and is run by the harness', () => {
  const sql = read('../supabase/tests/cafe_guest_01k_scan_final.sql')
  const code = sql.replace(/--[^\n]*/g, '')
  assert.match(code, /\\set ON_ERROR_STOP on\s*\n\s*begin;/)
  assert.match(code, /\brollback;\s*\n\s*select 'CAFE-GUEST-01K .* passed' as result;/)
  assert.doesNotMatch(code, /^\s*commit\s*;/im)
  assert.equal((code.match(/\\ir \.\.\/migrations\/20260926180000_cafe_guest_01k_scan_final\.sql/g) || []).length, 2, 're-applied twice: over an edited+offline Scan, and over a 01H-only Scan')
  for (const required of [
    /Scan must exist exactly once/, /Scan must be live \(published \+ available\)/, /pricing_definition must be PER_UNIT R5 x 1\.\.300/,
    /channels must stay the pinned counter-only decision/, /Scan must price 1 -> R5, 4 -> R20, 100 -> R500, 300 -> R1500/,
    /a quantity key must be ignored/, /quantity cannot substitute for units/, /the public catalogue must not return Scan, even though it is live/,
    /Scan on a storefront order/, /a zero price/, /a zero maximum/, /a fractional-cent price/,
    /editing Scan must not change A4\/A3 Lamination at all/, /editing A4 Lamination must not change the Scan row at all/,
    /re-applying must not overwrite the edited Scan price/, /re-applying must not republish a Scan an admin took offline/,
    /the migration must take a 01H-only Scan to the approved live values/, /A4 and A3 Lamination must be exactly as 01J left them/
  ]) assert.match(code, required)
  assert.match(sql, /the TEST'S OWN numbers/)
})

test('the new test file is part of npm test', () => {
  assert.match(JSON.parse(read('../package.json')).scripts.test, /tests\/scan-product\.test\.mjs/)
})
