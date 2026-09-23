import assert from 'node:assert/strict'
import test from 'node:test'
import { resolveStickyConfigureVisibility, resolveBottomNavActiveId } from '../src/lib/navigation.js'
import {
  BUSINESS_NAME,
  BUSINESS_TAGLINE,
  LOCATION_DISPLAY_NAME,
  BUSINESS_ADDRESS_LINES,
  WHATSAPP_NUMBER,
  WHATSAPP_DISPLAY,
  WHATSAPP_URL,
  buildWhatsappUrl,
  DELIVERY_INFO,
  RETURNS_POLICY_TEXT,
  PAYMENT_TRUST_TEXT
} from '../src/lib/businessInfo.js'
import { buildShareLinks } from '../src/lib/productContent.js'
import { calculateProductPrice } from '../src/lib/pricing.js'
import { resolveOfferPriceDisplay, calculateOfferPrice } from '../src/lib/offers.js'
import { products, offers } from '../src/data/products.js'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const __dirname = path.dirname(fileURLToPath(import.meta.url))
const repoRoot = path.resolve(__dirname, '..')

// ── QS-21.5 — Mobile shell + footer + fulfilment/payment trust ─────────
// App.jsx/Footer.jsx/MobileBottomNav.jsx/ProductSupportInfo.jsx are not
// unit-tested (no jsdom/React-rendering harness - see navigation.test.mjs's
// own note). These exercise the pure logic and real business-data
// content this pass added or changed. DOM-level behavior (bottom nav
// hide/show lifecycle, the sticky-CTA fix, footer nav wiring, the
// document-upload overlap fix, accordion open/close, no horizontal
// overflow at 360/375/390/430/768/1440) was verified live with
// Playwright - see the QS-21.5 report.

test('LOCATION_DISPLAY_NAME is the real customer-facing label, never "Location 001"', () => {
  assert.equal(LOCATION_DISPLAY_NAME, 'Kite Cres, Riverside View')
})

// Strips /* ... */ and //... comments before searching - this pass's own
// explanatory comments legitimately mention the string "Location 001"
// (documenting what NOT to show), which would otherwise false-positive
// this check against the very comments explaining the fix.
function stripComments(source) {
  return source.replace(/\/\*[\s\S]*?\*\//g, '').replace(/\/\/.*$/gm, '')
}

test('"Location 001" does not appear as real (non-comment) source anywhere in customer-facing code (App.jsx, every component/lib) - admin-only files are exempt', () => {
  const customerFacingDirs = ['src', 'src/components', 'src/lib']
  const offenders = []
  for (const dir of customerFacingDirs) {
    const fullDir = path.join(repoRoot, dir)
    for (const entry of fs.readdirSync(fullDir, { withFileTypes: true })) {
      if (!entry.isFile() || !/\.(jsx?|mjs)$/.test(entry.name)) continue
      const filePath = path.join(fullDir, entry.name)
      const content = stripComments(fs.readFileSync(filePath, 'utf8'))
      if (/location 001/i.test(content)) offenders.push(path.relative(repoRoot, filePath))
    }
  }
  assert.deepEqual(offenders, [])
})

test('WhatsApp business details: number, display form and URL are exactly the real ones', () => {
  assert.equal(WHATSAPP_NUMBER, '27693505865')
  assert.equal(WHATSAPP_DISPLAY, '+27 69 350 5865')
  assert.equal(WHATSAPP_URL, 'https://wa.me/27693505865')
})

test('buildWhatsappUrl: with no text returns the plain URL; with text appends ?text=<value> unchanged (caller pre-encodes)', () => {
  assert.equal(buildWhatsappUrl(), 'https://wa.me/27693505865')
  assert.equal(buildWhatsappUrl('hello'), 'https://wa.me/27693505865?text=hello')
})

test('the old WhatsApp number no longer appears anywhere in src/ - every call site now imports from businessInfo.js', () => {
  const offenders = []
  const walk = (dir) => {
    for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
      const full = path.join(dir, entry.name)
      if (entry.isDirectory()) walk(full)
      else if (/\.(jsx?|mjs)$/.test(entry.name)) {
        const content = fs.readFileSync(full, 'utf8')
        if (content.includes('27754534646')) offenders.push(path.relative(repoRoot, full))
      }
    }
  }
  walk(path.join(repoRoot, 'src'))
  assert.deepEqual(offenders, [])
})

test('business identity constants match the brief exactly', () => {
  assert.equal(BUSINESS_NAME, 'Quick Solution')
  assert.equal(BUSINESS_TAGLINE, 'by Joint X')
  assert.deepEqual(BUSINESS_ADDRESS_LINES, ['13 Kite Cres', 'Riverside View', 'Midrand', 'South Africa'])
})

test('DELIVERY_INFO: local collection/delivery facts match the REAL checkout fulfilmentOptions (never contradicts the actual selectable options)', () => {
  const localIds = DELIVERY_INFO.filter((item) => item.id !== 'courier').map((item) => item.title)
  assert.deepEqual(localIds, ['Collect locally', 'Local delivery'])
})

test('DELIVERY_INFO: PAXI/courier is presented as "available on request", never as an instant/automatic checkout option - honest about the real gap (no PAXI logic exists in the order RPC)', () => {
  const courier = DELIVERY_INFO.find((item) => item.id === 'courier')
  assert.ok(courier)
  assert.match(courier.helper, /message us|arrange|request/i)
  assert.doesNotMatch(courier.helper, /instant|automatic|calculated at checkout/i)
})

test('RETURNS_POLICY_TEXT matches the brief\'s own conservative fallback wording exactly (no source policy exists in the repo to draw from - confirmed by audit)', () => {
  assert.equal(
    RETURNS_POLICY_TEXT,
    "Because many items are made or printed to order, return eligibility depends on the product and issue. If there is a production problem or your order is incorrect, contact us and we'll review it."
  )
})

test('PAYMENT_TRUST_TEXT is the conservative "Secure checkout via PayFast" claim, never naming a specific card/EFT/wallet method (none could be verified as enabled on the merchant account)', () => {
  assert.equal(PAYMENT_TRUST_TEXT, 'Secure checkout via PayFast')
  for (const method of ['Visa', 'Mastercard', 'Apple Pay', 'Google Pay', 'Instant EFT', 'Capitec Pay', 'MukuruPay']) {
    assert.ok(!PAYMENT_TRUST_TEXT.includes(method), `PAYMENT_TRUST_TEXT must not claim "${method}" is enabled`)
  }
})

test('buildShareLinks now defaults to the real business WhatsApp number', () => {
  const links = buildShareLinks({ id: 'x', name: 'Test Product' })
  assert.match(links.whatsappUrl, new RegExp(`^https://wa\\.me/${WHATSAPP_NUMBER}\\?text=`))
})

test('resolveStickyConfigureVisibility also governs the mobile sticky CTA (ProductHub.jsx) - same function, same rule, cannot disagree with the desktop one', () => {
  assert.equal(resolveStickyConfigureVisibility('product', false), true)
  assert.equal(resolveStickyConfigureVisibility('product', true), false)
})

test('resolveBottomNavActiveId: Home is active on the home page', () => {
  assert.equal(resolveBottomNavActiveId('home', false), 'home')
})

test('resolveBottomNavActiveId: Shop is active on both the Shop catalogue and Product Detail (reached only via Shop)', () => {
  assert.equal(resolveBottomNavActiveId('shop', false), 'shop')
  assert.equal(resolveBottomNavActiveId('product', false), 'shop')
})

test('resolveBottomNavActiveId: Order takes priority whenever the basket is open, regardless of page', () => {
  assert.equal(resolveBottomNavActiveId('home', true), 'order')
  assert.equal(resolveBottomNavActiveId('shop', true), 'order')
  assert.equal(resolveBottomNavActiveId('product', true), 'order')
})

// ── Non-regression: pricing/cart/checkout behavior unchanged ──────────
test('non-regression: product pricing is unaffected by this pass - a known gazebo preset still prices at exactly the same pinned total', () => {
  const gazebos = products.find((product) => product.id === 'gazebos')
  const result = calculateProductPrice(gazebos, { variant: 'steel-2x2-full', quantity: 1, artwork: null })
  assert.equal(result.total, 5500)
})

test('non-regression: Offer pricing/display is unaffected - Business Starter still resolves a plain, non-"From" total', () => {
  const businessStarter = offers.find((offer) => offer.id === 'business-starter')
  const result = calculateOfferPrice(businessStarter, products)
  const display = resolveOfferPriceDisplay(businessStarter, result)
  assert.equal(display.priceText.startsWith('From'), false)
})
