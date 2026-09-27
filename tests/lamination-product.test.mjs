import assert from 'node:assert/strict'
import test from 'node:test'
import fs from 'node:fs'
import { products } from '../src/data/products.js'
import { buildPricingDefinition } from '../src/lib/pricingDefinition.js'
import { validatePerUnitDefinition } from '../src/lib/perUnitPricing.js'
import { calculateProductPrice, getDefaultConfig } from '../src/lib/pricing.js'
import { resolveCounterProduct, isCounterProduct, resolveCounterAction, resolveCounterGroup } from '../src/lib/counterCatalogue.js'
import { resolveShopCategory, resolveStartingPriceEligibility, resolveProductPriceCue, resolveHubAvailability } from '../src/lib/productContent.js'

// CAFE-GUEST-01J - A4 Lamination and A3 Lamination (PER_UNIT), replacing the generic
// 'lamination' placeholder of CAFE-GUEST-01I.
//
// Confirmed business decision: A4 R15 per sheet, A3 R30 per sheet, at most 100 sheets
// per order, only these two sizes. PER_UNIT has one unitPrice, so the size IS the
// product: two separate products, no size field, no variants, no priced options.
// The SQL counterpart, supabase/tests/cafe_guest_01j_lamination_a4_a3.sql, runs on the
// local harness (npm run test:sql) against the seeded rows.

const read = (path) => fs.readFileSync(new URL(path, import.meta.url), 'utf8').replace(/\r\n/g, '\n')
const MIGRATION = '../supabase/migrations/20260926170000_cafe_guest_01j_lamination_a4_a3.sql'
const migration = read(MIGRATION)
const migrationCode = migration.replace(/--[^\n]*/g, '')

const SPEC = {
  'a4-lamination': { size: 'A4', other: 'A3', price: 15, sort: 24, name: 'A4 Lamination' },
  'a3-lamination': { size: 'A3', other: 'A4', price: 30, sort: 25, name: 'A3 Lamination' }
}
const KEYS = Object.keys(SPEC)
const NINE = ['pvc-banner', 'vinyl-stickers', 'a4-print', 'business-cards', 'printed-tshirt', 'media-services', 'flags', 'gazebos', 'photo-session']
const byId = (id) => products.find((product) => product.id === id)
const a4 = byId('a4-lamination')
const a3 = byId('a3-lamination')
const scan = byId('scan')
const clone = (value) => JSON.parse(JSON.stringify(value))

const deepKeys = (value, keys = new Set()) => {
  if (Array.isArray(value)) value.forEach((item) => deepKeys(item, keys))
  else if (value && typeof value === 'object') for (const [key, child] of Object.entries(value)) { keys.add(key); deepKeys(child, keys) }
  return keys
}
const customerText = (product) => `${product.name} ${product.shortName} ${product.description} ${product.plainDescription} ${product.fields[0].label} ${product.fields[0].shortLabel} ${product.fields[0].suffix} ${product.fields[0].help}`

// ── identity: two concrete products, the generic one is gone ────────────
test('A4 Lamination and A3 Lamination each exist exactly once, with deliberate keys, names and category', () => {
  for (const [key, spec] of Object.entries(SPEC)) {
    assert.equal(products.filter((product) => product.id === key).length, 1, key)
    const product = byId(key)
    assert.equal(product.name, spec.name)
    assert.equal(product.shortName, spec.name)
    assert.equal(product.category, 'Quick Print')
    // 'Quick Print' is already mapped everywhere: shop bucket, counter group; no new category.
    assert.equal(resolveShopCategory(product), 'Print & Documents')
    assert.equal(resolveCounterGroup(product), 'Quick Services')
  }
  assert.deepEqual(products.map((product) => product.id).slice(9), ['scan', 'a4-lamination', 'a3-lamination'])
  assert.equal(products.length, 12, 'the nine originals, Scan, A4 and A3 - no other new product')
})

test('the key convention fits the repo: the a4-print prefix style, valid product slugs', () => {
  assert.ok(byId('a4-print'), 'the existing product that sets the a4- key convention')
  for (const key of KEYS) {
    assert.match(key, /^[a-z0-9]+(-[a-z0-9]+)*$/, 'the commerce.products slug format')
    assert.match(key, /^a[34]-lamination$/)
  }
})

test('the generic lamination product is not an intended sellable product any more, and no other size exists', () => {
  assert.equal(products.some((product) => product.id === 'lamination'), false)
  assert.deepEqual(products.filter((product) => /lamin/i.test(`${product.id} ${product.name}`)).map((product) => product.id), KEYS)
  for (const product of products) assert.doesNotMatch(`${product.id} ${product.name}`, /\ba[0-2]\b|\ba[5-9]\b|\ba1[0-9]\b|\bb[0-9]\b|letter|legal|pouch/i, product.id)
  // No source file other than the seeded data mentions lamination products at all.
  const walk = (dir, out = []) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const path = new URL(`${entry.name}${entry.isDirectory() ? '/' : ''}`, dir)
      if (entry.isDirectory()) walk(path, out)
      else if (/\.(jsx?|css)$/.test(entry.name)) out.push({ name: entry.name, text: fs.readFileSync(path, 'utf8') })
    }
    return out
  }
  const mentions = walk(new URL('../src/', import.meta.url)).filter((file) => /lamination['"]|a[34]-lamination/i.test(file.text)).map((file) => file.name)
  assert.deepEqual(mentions.sort(), ['counterSubmissionReadiness.js', 'products.js'], 'only the seeded data and the deliberate first-write rollout list (CAFE-GUEST-01O) name them: no code branch, no UI, no admin special case')
})

test('Scan (separate, finalized by 01K) and the nine original products are not touched by Lamination', () => {
  // Scan's own price and live state are CAFE-GUEST-01K's business (see scan-product.test.mjs);
  // what matters here is that it stays a separate product with its own deliberate channels.
  assert.ok(scan)
  assert.equal(scan.category, 'Quick Print')
  assert.deepEqual(scan.channels, { storefront: false, guided: false, pos: true, quote: false, advanced: false })
  assert.match(scan.fields[0].label, /pages/i)
  assert.deepEqual(clone(products.slice(0, 9)), JSON.parse(read('./fixtures/nine-products-before-scan.json')))
  assert.deepEqual(products.slice(0, 9).map((product) => product.id), NINE)
  // Scan's historical seed migration (01H) is still exactly what it was: the pending placeholder.
  const scanSeed = read('../supabase/migrations/20260926150000_cafe_guest_01h_scan_product.sql')
  assert.deepEqual(JSON.parse(scanSeed.match(/\$definition\$([\s\S]*?)\$definition\$/)[1]), { strategy: 'PER_UNIT', unitPrice: 0, minUnits: 1, maxUnits: 0 })
  // A4 and A3 are exactly as 01J left them (also proven, after Scan was finalized, in scan-product.test.mjs).
  assert.deepEqual(clone([a4, a3]), JSON.parse(read('./fixtures/lamination-products-before-scan-final.json')))
})

// ── confirmed pricing ──────────────────────────────────────────────────
test('A4 is R15 and A3 is R30 per sheet, minimum 1, maximum 100, exactly the four PER_UNIT keys', () => {
  assert.deepEqual(a4.pricing, { strategy: 'PER_UNIT', unitPrice: 15, minUnits: 1, maxUnits: 100 })
  assert.deepEqual(a3.pricing, { strategy: 'PER_UNIT', unitPrice: 30, minUnits: 1, maxUnits: 100 })
  for (const product of [a4, a3]) {
    assert.deepEqual(Object.keys(product.pricing), ['strategy', 'unitPrice', 'minUnits', 'maxUnits'])
    assert.equal(validatePerUnitDefinition(product.pricing).ok, true, product.id)
    assert.doesNotMatch(JSON.stringify(product), /setupFee|minimumCharge|tier|discount|variant|surcharge|multiplier|fee|option/i, product.id)
  }
  assert.notEqual(a4.pricing, a3.pricing, 'no shared object: each product owns its own price')
  assert.equal(a4.pricingVersion, '2026-09-qsc-17')
  assert.equal(a3.pricingVersion, '2026-09-qsc-17')
})

test('client pricing: A4 1 -> R15, 4 -> R60, 100 -> R1500; A3 1 -> R30, 4 -> R120, 100 -> R3000', () => {
  const table = [
    [a4, 1, 15], [a4, 4, 60], [a4, 100, 1500],
    [a3, 1, 30], [a3, 4, 120], [a3, 100, 3000]
  ]
  for (const [product, units, total] of table) {
    for (const value of [units, String(units)]) {
      const result = calculateProductPrice(product, { units: value })
      assert.equal(result.total, total, `${product.id} x ${value}`)
      assert.deepEqual(result.metrics, { units, unitPrice: product.pricing.unitPrice })
    }
  }
  assert.equal(calculateProductPrice(a4, { units: 4 }).summary, '4 × 15.00')
  assert.equal(calculateProductPrice(a3, { units: 4 }).summary, '4 × 30.00')
})

test('invalid unit counts are rejected for both products and never yield a usable total', () => {
  for (const product of [a4, a3]) {
    for (const units of [undefined, null, '', 'abc', 0, -1, 2.5, 101, '101', '007', '1e1', ' 3', true]) {
      const result = calculateProductPrice(product, units === undefined ? {} : { units })
      assert.equal(result.total, 0, `${product.id} ${String(units)}`)
      assert.equal(result.metrics.invalid, true, `${product.id} ${String(units)}`)
    }
    assert.equal(calculateProductPrice(product, { quantity: 3 }).total, 0, 'quantity is not units')
  }
})

// ── unit meaning and runtime configuration ─────────────────────────────
test('one unit is one physical sheet laminated once, counted by { units } and never by quantity', () => {
  for (const product of [a4, a3]) {
    assert.equal(product.fields.length, 1)
    const [field] = product.fields
    assert.equal(field.id, 'units')
    assert.equal(field.type, 'number')
    assert.equal(field.required, true)
    assert.equal(field.min, product.pricing.minUnits)
    assert.equal(field.step, 1, 'whole numbers only')
    assert.match(field.label, /sheets/i)
    assert.equal(field.suffix, 'sheets')
    assert.match(field.help, /each sheet once, even if it is printed on both sides/i)
    // Nothing that would go stale when an admin edits maxUnits later.
    assert.equal('max' in field, false)
    assert.equal('default' in field, false, 'no default count')
    assert.equal(getDefaultConfig(product, {}).units, '')
    assert.equal('quantity' in getDefaultConfig(product, {}), false)
    assert.equal(deepKeys(product).has('quantity'), false)
    assert.doesNotMatch(JSON.stringify(product), /quantity/i)
    // A sheet, never a page.
    assert.doesNotMatch(customerText(product), /\bpages?\b/i, product.id)
  }
  assert.doesNotMatch(migrationCode, /quantity/i)
  assert.match(scan.fields[0].label, /pages/i, 'Scan still counts pages; the two units are never mixed')
})

test('size is the product: no size field, no variants, no options, no priced options, and each names only its own size', () => {
  for (const [key, spec] of Object.entries(SPEC)) {
    const product = byId(key)
    assert.deepEqual(product.fields.map((field) => field.id), ['units'])
    assert.equal('options' in product.fields[0], false)
    assert.doesNotMatch(JSON.stringify(product), /variant|option|helper|multiplier|unitFee|"size"/i)
    assert.match(customerText(product), new RegExp(`\\b${spec.size}\\b`))
    assert.doesNotMatch(customerText(product), new RegExp(`\\b${spec.other}\\b`), `${key} must not mention ${spec.other}`)
    assert.doesNotMatch(JSON.stringify(product.keywords), new RegExp(`\\b${spec.other}\\b`, 'i'))
  }
})

test('no upload: neither product has a file field or a file requirement', () => {
  for (const product of [a4, a3]) {
    assert.equal(product.fields.some((field) => field.type === 'file' || field.id === 'file'), false)
    assert.doesNotMatch(JSON.stringify(product), /upload|fileName|artwork/i)
  }
})

test('the customer pricing mirror exposes only the four allowed pricing fields and nothing private', () => {
  for (const product of [a4, a3]) {
    assert.deepEqual(Object.keys(product.pricing).sort(), ['maxUnits', 'minUnits', 'strategy', 'unitPrice'])
    assert.doesNotMatch(JSON.stringify(product), /supplier|margin|referencePrice|sourceUrl|sourceName|pricingDefinition|pricing_definition|vat/i)
    assert.equal('pricingDefinition' in product, false)
  }
})

// ── live state, channels, orderability ─────────────────────────────────
test('they are live and priced (not blocked), yet counter-only: never on the storefront', () => {
  for (const product of [a4, a3]) {
    assert.equal(product.active, true, 'approved pricing: live, like every earlier seeded product with an approved price')
    assert.equal(product.popular, false)
    assert.doesNotThrow(() => buildPricingDefinition(product), 'the admin save accepts the confirmed pricing')
    const storefrontRule = (item) => item.active !== false && item.channels?.storefront !== false
    assert.equal(storefrontRule(product), false)
    assert.deepEqual(resolveStartingPriceEligibility(product), { mode: 'none' })
    assert.equal(resolveProductPriceCue(product), null)
    assert.equal(product.productPage, undefined)
  }
  assert.match(read('../src/App.jsx'), /catalog\.filter\(\(product\) => product\.active !== false && product\.channels\?\.storefront !== false\)/)
})

test('channel decisions are pinned: pos true, every customer-facing channel off', () => {
  for (const product of [a4, a3]) {
    assert.deepEqual(product.channels, { storefront: false, guided: false, pos: true, quote: false, advanced: false })
    assert.equal(product.guidedJourneyId, undefined)
    assert.equal(isCounterProduct(product), true, 'staff may start it for a walk-in customer')
    assert.deepEqual(resolveHubAvailability(product, { onGuided: () => {}, onConfigure: () => {} }), { hasGuided: false, hasAdvanced: false })
  }
})

test('counter action is order and group is Quick Services, through the generic rules with no Lamination branch', () => {
  for (const product of [a4, a3]) {
    assert.equal(resolveCounterAction(product), 'order')
    assert.deepEqual({ ...resolveCounterProduct(product), product: undefined }, { product: undefined, visible: true, action: 'order', group: 'Quick Services' })
  }
  const code = (file) => read(file).replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/[^\n]*/g, '')
  for (const file of ['../src/lib/counterCatalogue.js', '../src/lib/pricing.js', '../src/lib/perUnitPricing.js', '../src/lib/pricingDefinition.js', '../src/lib/counterPrintConfig.js']) {
    assert.doesNotMatch(code(file), /lamin/i, file)
  }
})

// ── admin: independent editing through the existing PER_UNIT path ───────
test('admin round-trips each product independently, and a future price or maximum change needs no code', () => {
  assert.deepEqual(buildPricingDefinition(a4), { strategy: 'PER_UNIT', unitPrice: 15, minUnits: 1, maxUnits: 100 })
  assert.deepEqual(buildPricingDefinition(a3), { strategy: 'PER_UNIT', unitPrice: 30, minUnits: 1, maxUnits: 100 })
  for (const product of [a4, a3]) assert.deepEqual(JSON.parse(JSON.stringify(buildPricingDefinition(product))), buildPricingDefinition(product))

  // Editing A4 (price and maximum, as the generic admin editor does) leaves A3 untouched, and vice versa.
  const a3Before = clone(a3)
  const editedA4 = { ...clone(a4), pricing: { ...a4.pricing, unitPrice: 18.5, maxUnits: 40 } }
  assert.deepEqual(buildPricingDefinition(editedA4), { strategy: 'PER_UNIT', unitPrice: 18.5, minUnits: 1, maxUnits: 40 })
  assert.equal(calculateProductPrice(editedA4, { units: 4 }).total, 74)
  assert.equal(calculateProductPrice(editedA4, { units: 41 }).total, 0, 'the edited maximum applies')
  assert.deepEqual(clone(a3), a3Before, 'editing A4 did not mutate A3')
  assert.deepEqual(buildPricingDefinition(a3), { strategy: 'PER_UNIT', unitPrice: 30, minUnits: 1, maxUnits: 100 })
  assert.equal(calculateProductPrice(a3, { units: 4 }).total, 120)

  const a4Before = clone(a4)
  const editedA3 = { ...clone(a3), pricing: { ...a3.pricing, unitPrice: 32, maxUnits: 60 } }
  assert.deepEqual(buildPricingDefinition(editedA3), { strategy: 'PER_UNIT', unitPrice: 32, minUnits: 1, maxUnits: 60 })
  assert.deepEqual(clone(a4), a4Before, 'editing A3 did not mutate A4')
  assert.equal(calculateProductPrice(a4, { units: 4 }).total, 60)

  // The admin still refuses an invalid edit, for either product.
  for (const product of [a4, a3]) {
    assert.throws(() => buildPricingDefinition({ ...clone(product), pricing: { ...product.pricing, unitPrice: 0 } }), /unitPrice must be greater than 0/)
    assert.throws(() => buildPricingDefinition({ ...clone(product), pricing: { ...product.pricing, unitPrice: 12.345 } }), /whole cents/)
    assert.throws(() => buildPricingDefinition({ ...clone(product), pricing: { ...product.pricing, maxUnits: 0 } }), /maxUnits must be at least minUnits/)
  }
  // The generic editor already renders every numeric pricing key of both.
  for (const product of [a4, a3]) {
    assert.deepEqual(Object.entries(product.pricing).filter(([key, value]) => key !== 'strategy' && typeof value === 'number').map(([key]) => key), ['unitPrice', 'minUnits', 'maxUnits'])
  }
})

// ── the forward migration ──────────────────────────────────────────────
test('the migration seeds A4 and A3 live, once each, and each JSON block is exactly the client product', () => {
  const customers = [...migration.matchAll(/\$customer\$([\s\S]*?)\$customer\$/g)].map((match) => JSON.parse(match[1]))
  const definitions = [...migration.matchAll(/\$definition\$([\s\S]*?)\$definition\$/g)].map((match) => JSON.parse(match[1]))
  assert.deepEqual(customers.map((customer) => customer.id), KEYS)
  assert.equal(definitions.length, 2)
  KEYS.forEach((key, index) => {
    const { pricingVersion, ...clientDefinition } = byId(key)
    assert.deepEqual(customers[index], clientDefinition, `${key} customer_definition equals the client product (minus pricingVersion)`)
    assert.deepEqual(definitions[index], byId(key).pricing, `${key} pricing_definition equals the client pricing`)
    assert.deepEqual(customers[index].pricing, definitions[index], 'mirror equals the definition')
    assert.equal(pricingVersion, '2026-09-qsc-17')
  })
  assert.equal((migrationCode.match(/'2026-09-qsc-17',/g) || []).length, 2)
  assert.equal((migrationCode.match(/insert into commerce\.products/g) || []).length, 2)
  assert.equal((migrationCode.match(/insert into commerce\.service_product_configs/g) || []).length, 2)
  // Live, in the state every earlier seeded approved product used.
  assert.equal((migrationCode.match(/'ZAR',\s*'available',\s*'published',/g) || []).length, 2)
  assert.deepEqual([...migrationCode.matchAll(/\$definition\$::jsonb,\s*'(\w+)',\s*(\d+)\s+from/g)].map((match) => [match[1], Number(match[2])]), [['published', 24], ['published', 25]])
  // Insert-if-absent: it can never overwrite a price or maximum an admin edited.
  assert.equal((migrationCode.match(/and not exists \(\s*select 1\s*from commerce\.products p\s*where p\.tenant_id = t\.id and p\.slug = '(a4|a3)-lamination'\s*\)/g) || []).length, 2)
  assert.equal((migrationCode.match(/on conflict \(tenant_id, source_key\) do nothing;/g) || []).length, 2)
})

test('the generic lamination is retired, not deleted, and only if it exists and is not already retired', () => {
  const bare = migrationCode.replace(/\$(customer|definition)\$[\s\S]*?\$\1\$/g, "''")
  const configUpdate = bare.match(/update commerce\.service_product_configs c[\s\S]*?;\n/)[0]
  const productUpdate = bare.match(/update commerce\.products p[\s\S]*?;\n/)[0]
  assert.match(configUpdate, /set status = 'archived'/)
  assert.match(configUpdate, /'\{"storefront": false, "guided": false, "pos": false, "quote": false, "advanced": false\}'::jsonb/, 'every channel off, pos included')
  assert.match(configUpdate, /jsonb_set\(c\.customer_definition, '\{active\}', 'false'::jsonb, true\)/)
  assert.match(configUpdate, /pricing_version = case when c\.pricing_version like '%-retired' then c\.pricing_version else c\.pricing_version \|\| '-retired' end/, 'the marker never stacks')
  assert.match(configUpdate, /c\.source_key = 'lamination'\s+and c\.status <> 'archived'/)
  assert.match(productUpdate, /set status = 'archived',\s*availability = 'unavailable'/)
  assert.match(productUpdate, /p\.slug = 'lamination'\s+and \(p\.status <> 'archived' or p\.availability <> 'unavailable'\)/)
  // What an admin may have entered on it is kept: only these columns are written.
  assert.deepEqual([...configUpdate.matchAll(/^\s*(?:set\s+)?(\w+) = /gm)].map((match) => match[1]), ['status', 'customer_definition', 'pricing_version', 'updated_at'])
  assert.deepEqual([...productUpdate.matchAll(/^\s*(?:set\s+)?(\w+) = /gm)].map((match) => match[1]), ['status', 'availability', 'updated_at'])
  assert.doesNotMatch(bare, /\bdelete\b|\btruncate\b|\bdrop\b/i)
})

test('the migration touches nothing else: no other product, no function, grant or table, and no transaction control', () => {
  const bare = migrationCode.replace(/\$(customer|definition)\$[\s\S]*?\$\1\$/g, "''").replace(/'(?:[^']|'')*'/g, "''")
  assert.deepEqual([...bare.matchAll(/\binsert\s+into\s+([\w.]+)/gi)].map((match) => match[1]), ['commerce.products', 'commerce.service_product_configs', 'commerce.products', 'commerce.service_product_configs'])
  assert.deepEqual([...bare.matchAll(/\bupdate\s+([\w.]+)/gi)].map((match) => match[1]), ['commerce.service_product_configs', 'commerce.products'])
  assert.doesNotMatch(bare, /\b(alter|drop|grant|revoke|truncate|delete)\b/i)
  assert.doesNotMatch(bare, /\bcreate\s+(or replace\s+)?(function|table|trigger|policy|index|view)\b/i)
  assert.doesNotMatch(bare, /^\s*(begin|commit|rollback)\s*;/im, 'no BEGIN/COMMIT, so the SQL test can re-apply it inside its own transaction')
  assert.doesNotMatch(migrationCode, /\bscan\b/i)
  assert.match(migration, /to_regprocedure\('commerce\._qs_validate_per_unit_definition\(jsonb\)'\) is null/)
})

test('the previous placeholder migration is left as history, and the forward migration follows it', () => {
  const files = fs.readdirSync(new URL('../supabase/migrations/', import.meta.url)).filter((name) => name.endsWith('.sql')).sort()
  assert.ok(files.includes('20260926170000_cafe_guest_01j_lamination_a4_a3.sql'), 'still present; later migrations (01K, Scan) do not touch it')
  const historic = '20260926160000_cafe_guest_01i_lamination_product.sql'
  assert.ok(files.includes(historic), 'not rewritten or deleted: it may already have been applied somewhere')
  assert.ok(files.indexOf(historic) < files.indexOf('20260926170000_cafe_guest_01j_lamination_a4_a3.sql'))
  const old = read(`../supabase/migrations/${historic}`)
  assert.match(old, /'lamination',\s*\n\s*'Lamination'/)
  assert.match(old, /'ZAR',\s*'unavailable',\s*'draft'/)
  assert.match(old, /on conflict \(tenant_id, source_key\) do nothing/)
})

test('the SQL contract test is rollback-contained, re-applies the migration in-transaction, and is run by the harness', () => {
  const sql = read('../supabase/tests/cafe_guest_01j_lamination_a4_a3.sql')
  const code = sql.replace(/--[^\n]*/g, '')
  assert.match(code, /\\set ON_ERROR_STOP on\s*\n\s*begin;/)
  assert.match(code, /\brollback;\s*\n\s*select 'CAFE-GUEST-01J .* passed' as result;/)
  assert.doesNotMatch(code, /^\s*commit\s*;/im)
  assert.equal((code.match(/\\ir \.\.\/migrations\/20260926170000_cafe_guest_01j_lamination_a4_a3\.sql/g) || []).length, 2, 're-applied twice: over edited data, and with no placeholder')
  for (const required of [
    /must exist exactly once/, /must be live \(published \+ available\)/, /pricing_definition must be PER_UNIT R% x 1\.\.100/,
    /channels must be the pinned counter-only decision/, /A4 must price 1 -> R15, 4 -> R60, 100 -> R1500/, /A3 must price 1 -> R30, 4 -> R120, 100 -> R3000/,
    /a quantity key must be ignored/, /generic lamination must be archived/, /the retired generic lamination cannot be priced/,
    /no size other than A4 and A3 may exist/, /Scan is untouched/, /the public catalogue must still return exactly the nine original products/,
    /editing A4 must not change the A3 row at all/, /editing A3 must not change the A4 row at all/,
    /re-applying must not overwrite the edited A4/, /re-applying must retire the re-activated placeholder again/,
    /retirement must keep the price an admin entered/, /the retired marker must not stack/, /re-applying must not duplicate/,
    /with no placeholder the migration must not create one/, /the retired generic lamination must not appear in the admin catalogue/
  ]) assert.match(code, required)
  assert.match(sql, /the TEST'S OWN numbers/)
})

test('the new test file is part of npm test', () => {
  assert.match(JSON.parse(read('../package.json')).scripts.test, /tests\/lamination-product\.test\.mjs/)
})
