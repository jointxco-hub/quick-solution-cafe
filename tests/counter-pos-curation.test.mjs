import assert from 'node:assert/strict'
import test from 'node:test'
import fs from 'node:fs'
import { products } from '../src/data/products.js'
import { isCounterProduct } from '../src/lib/counterCatalogue.js'

// CAFE-GUEST-01E - the reviewed channels.pos decisions.
//
// Decision question, asked of every product:
//   "May Cafe staff intentionally initiate this product or service for a
//    walk-in customer?"
//
// channels.pos = true means a staff-assisted sale or request at the physical
// Cafe counter. It does NOT mean instant service, no production, automatically
// payable, or authorized; a production job may still originate at the counter
// (channel = 'counter'). It was not inferred from active, published state,
// pricing strategy or storefront state. Each decision below rests on the
// product definitions in the repository, and none of the original nine has a
// concrete source-level reason to be kept off the counter, so all nine remain
// true. CAFE-GUEST-01H adds Scan and CAFE-GUEST-01J adds A4 and A3 Lamination, each
// decided on the same question (true; the only counter-only products: none has a
// storefront path). The generic 01I 'lamination' placeholder is retired and is not
// a product any more, so it has no decision.
//
// This is a record of a REVIEW, not of a permanent rule. A new product, or a
// changed decision, must be added or edited here on purpose - that is the
// point of the "every product has a decision" test. Live values could differ
// from the repository (admin edits persist); reading them needs a separate,
// authorized, read-only check.
export const POS_REVIEW_QUESTION = 'May Cafe staff intentionally initiate this product or service for a walk-in customer?'

const REVIEWED = {
  'a4-print': {
    pos: true,
    reason: 'Core walk-in service. A physical, no-file job is valid: the server needs only page counts in documentInstructions, never an uploaded file.'
  },
  'pvc-banner': {
    pos: true,
    reason: 'Fully server-priced PER_AREA order (width and height); artwork upload is optional; production continues through the normal order and handoff path.'
  },
  'vinyl-stickers': {
    pos: true,
    reason: 'Fully server-priced PER_AREA order; artwork upload is optional; production continues through the normal order and handoff path.'
  },
  'business-cards': {
    pos: true,
    reason: 'Fully server-priced TIERED order with fixed quantity options; design help is a priced option and a file is optional; production follows.'
  },
  'printed-tshirt': {
    pos: true,
    reason: 'Fully server-priced CONFIGURABLE order; artwork is optional; production follows. Its own quantity field is the product quantity, unlike print jobs.'
  },
  flags: {
    pos: true,
    reason: 'Fully priced supplier-margin variants that staff can order for a walk-in. The pair-of-2 rule for single-sided flags is enforced by the server through quantity rules, so staff satisfy it by entering the quantity; it is not an obstacle.'
  },
  gazebos: {
    pos: true,
    reason: 'Fully priced supplier-margin variants that staff can order for a walk-in; supplier ordering and production follow through handoff.'
  },
  'media-services': {
    pos: true,
    reason: 'Enquiry: staff can start a request for a walk-in customer (the shoot location may be the Cafe). It is a quote request through the service-request path and is never a paid order.'
  },
  'photo-session': {
    pos: true,
    reason: 'Booking request through the service-request path, for a session at the Cafe. It is never a paid checkout item. The unresolved active-state drift between the client default and the qs14 data is deliberately not used in this decision.'
  },
  scan: {
    pos: true,
    reason: 'Cafe staff scan a walk-in customer\'s paper documents at the counter: the originals are physical and only staff can take them in. It is a per-page PER_UNIT order with no file to upload. It has no storefront path at all, so the counter is its only channel.'
  },
  'a4-lamination': {
    pos: true,
    reason: 'Cafe staff laminate the A4 sheets a walk-in customer hands over: the item is physical and only staff can take it in and hand it back. It is a per-sheet PER_UNIT order with no file to upload. It has no storefront path at all, so the counter is its only channel.'
  },
  'a3-lamination': {
    pos: true,
    reason: 'Cafe staff laminate the A3 sheets a walk-in customer hands over: the item is physical and only staff can take it in and hand it back. It is a per-sheet PER_UNIT order with no file to upload. It has no storefront path at all, so the counter is its only channel.'
  }
}

const read = (path) => fs.readFileSync(new URL(path, import.meta.url), 'utf8')

// pos as stored in the repository's database definitions, per product key.
function databasePosValues() {
  const found = new Map()

  const seed = read('../supabase/seed.sql')
  for (const match of seed.matchAll(/select t\.id, p\.id, '([\w-]+)',\s*'(\{[\s\S]*?\})'::jsonb,/g)) {
    found.set(match[1], JSON.parse(match[2].replace(/''/g, "'")).channels?.pos)
  }

  const qs14 = read('../supabase/migrations/20260921090500_qs14_catalog_data.sql')
  for (const match of qs14.matchAll(/select\s+t\.id,\s+p\.id,\s+'([\w-]+)',\s+\$cd\$([\s\S]*?)\$cd\$/g)) {
    found.set(match[1], JSON.parse(match[2]).channels?.pos)
  }

  // These two files each define one product with jsonb_build_object.
  for (const [file, key] of [
    ['../supabase/migrations/20260915150000_qs11_vinyl_stickers_catalog.sql', 'vinyl-stickers'],
    ['../supabase/migrations/20260915213000_qs12_media_services.sql', 'media-services']
  ]) {
    const blocks = [...read(file).matchAll(/'channels',\s*jsonb_build_object\(([^)]*)\)/g)]
    assert.equal(blocks.length, 1, `${file} must define exactly one channels block`)
    const pos = blocks[0][1].match(/'pos',\s*(true|false)/)
    found.set(key, pos ? pos[1] === 'true' : undefined)
  }

  // Scan (CAFE-GUEST-01H) is defined as a JSON literal.
  // The 01I generic placeholder is deliberately not read: it is retired by 01J.
  const scanBlock = read('../supabase/migrations/20260926150000_cafe_guest_01h_scan_product.sql').match(/\$customer\$([\s\S]*?)\$customer\$/)
  found.set('scan', JSON.parse(scanBlock[1]).channels?.pos)
  for (const match of read('../supabase/migrations/20260926170000_cafe_guest_01j_lamination_a4_a3.sql').matchAll(/\$customer\$([\s\S]*?)\$customer\$/g)) {
    const definition = JSON.parse(match[1])
    found.set(definition.id, definition.channels?.pos)
  }
  return found
}

test('every product in the catalogue has a reviewed decision, and no decision is for an unknown product', () => {
  assert.deepEqual(products.map((product) => product.id).sort(), Object.keys(REVIEWED).sort())
  assert.equal(products.length, 12, 'the nine original products plus Scan, A4 Lamination and A3 Lamination')
})

test('each decision is a boolean with a stated reason, and the review records nothing else', () => {
  for (const [key, decision] of Object.entries(REVIEWED)) {
    assert.deepEqual(Object.keys(decision), ['pos', 'reason'], key)
    assert.equal(typeof decision.pos, 'boolean', key)
    assert.ok(decision.reason.length > 40, `${key} needs a real reason`)
    // pos is not instant service, no production, payability or authorization.
    assert.doesNotMatch(decision.reason, /\b(instant|no production|automatically payable|authoriz)/i, key)
  }
  assert.match(POS_REVIEW_QUESTION, /^May Cafe staff intentionally initiate this product or service for a walk-in customer\?$/)
})

test('the client catalogue records exactly the reviewed decision for every product', () => {
  for (const product of products) {
    assert.strictEqual(product.channels?.pos, REVIEWED[product.id].pos, product.id)
    assert.equal(isCounterProduct(product), REVIEWED[product.id].pos, product.id)
  }
})

test('the database definitions in the repository record the same decisions', () => {
  const stored = databasePosValues()
  assert.deepEqual([...stored.keys()].sort(), Object.keys(REVIEWED).sort(), 'every product has a database definition')
  for (const [key, decision] of Object.entries(REVIEWED)) {
    assert.strictEqual(stored.get(key), decision.pos, key)
  }
})

test('the review changed no other channel: storefront, guided, quote and advanced are as they were, except the counter-only Scan and Lamination products', () => {
  const counterOnly = ['scan', 'a4-lamination', 'a3-lamination']
  for (const product of products.filter((item) => !counterOnly.includes(item.id))) {
    assert.strictEqual(product.channels.storefront, true, product.id)
    assert.strictEqual(product.channels.guided, true, product.id)
    assert.strictEqual(product.channels.quote, true, product.id)
  }
  // Scan and Lamination: counter-only. Every customer-facing channel is off, deliberately.
  for (const id of counterOnly) {
    assert.deepEqual(products.find((product) => product.id === id).channels, { storefront: false, guided: false, pos: true, quote: false, advanced: false }, id)
  }
  // The only products that opt out of the full-options view.
  assert.deepEqual(products.filter((product) => product.channels.advanced === false).map((product) => product.id).sort(), ['a3-lamination', 'a4-lamination', 'media-services', 'photo-session', 'scan'])
})

test('the unresolved photo-session active-state drift is left exactly as found', () => {
  assert.equal(products.find((product) => product.id === 'photo-session').active, false, 'client default')
  const qs14 = read('../supabase/migrations/20260921090500_qs14_catalog_data.sql')
  const match = qs14.match(/select\s+t\.id,\s+p\.id,\s+'photo-session',\s+\$cd\$([\s\S]*?)\$cd\$/)
  assert.strictEqual(JSON.parse(match[1]).active, true, 'qs14 data')
})

test('the new test file is part of npm test', () => {
  assert.match(JSON.parse(read('../package.json')).scripts.test, /tests\/counter-pos-curation\.test\.mjs/)
})
