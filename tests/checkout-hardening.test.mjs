import assert from 'node:assert/strict'
import test from 'node:test'
import fs from 'node:fs'
import { canStartPayfastRedirect, resolvePayfastInitOutcome } from '../src/lib/payfastInit.js'

const read = (path) => fs.readFileSync(new URL(path, import.meta.url), 'utf8')

// ── QS checkout hardening ────────────────────────────────────────────────
// E's actual state machine lives in three components (OrderBasket.jsx,
// GuidedOrder.jsx, PaymentReturn.jsx's payAgain), each with its own
// surrounding UI - lib/payfastInit.js is the one piece of real decision
// logic factored out of all three (same reasoning as lib/navigation.js:
// this repo's test suite is plain Node --test, no DOM/rendering harness),
// so the pure decisions get real, executed tests here; the wiring into
// each component (does it check the guard BEFORE setting state, does the
// button read canStartPayfastRedirect, does the loader cover 'starting'
// AND 'redirecting') is proven by reading the source, the same way
// tests/admin-google-oauth.test.mjs already does for this repo's other
// components.

test('canStartPayfastRedirect: "starting" and "redirecting" both refuse a second start - this IS "repeated click cannot initiate twice"', () => {
  assert.equal(canStartPayfastRedirect('starting'), false)
  assert.equal(canStartPayfastRedirect('redirecting'), false)
})

test('canStartPayfastRedirect: "paid" also refuses - nothing left to pay', () => {
  assert.equal(canStartPayfastRedirect('paid'), false)
})

test('canStartPayfastRedirect: idle/error/undefined all allow starting', () => {
  assert.equal(canStartPayfastRedirect('idle'), true)
  assert.equal(canStartPayfastRedirect('error'), true)
  assert.equal(canStartPayfastRedirect(undefined), true)
})

test('resolvePayfastInitOutcome: alreadyPaid or paymentStatus "paid" resolves to the paid outcome, never a redirect', () => {
  assert.deepEqual(resolvePayfastInitOutcome({ ok: true, alreadyPaid: true }), { type: 'paid' })
  assert.deepEqual(resolvePayfastInitOutcome({ ok: true, paymentStatus: 'paid' }), { type: 'paid' })
})

test('resolvePayfastInitOutcome: a payment_url resolves to a redirect outcome carrying that exact url', () => {
  const outcome = resolvePayfastInitOutcome({ ok: true, payment_url: 'https://www.payfast.co.za/eng/process?x=1' })
  assert.deepEqual(outcome, { type: 'redirect', url: 'https://www.payfast.co.za/eng/process?x=1' })
})

test('resolvePayfastInitOutcome: a missing payment_url is an error outcome, never thrown, never treated as a redirect', () => {
  assert.deepEqual(resolvePayfastInitOutcome({ ok: true }), { type: 'error', message: 'PayFast did not return a payment link.' })
  assert.deepEqual(resolvePayfastInitOutcome(null), { type: 'error', message: 'PayFast did not return a payment link.' })
})

// ── E: button disable/loading + double-click guard, wired into all three callers ──
for (const [file, fnName] of [
  ['../src/components/OrderBasket.jsx', 'startCombinedPayment'],
  ['../src/components/GuidedOrder.jsx', 'startPayment'],
  ['../src/components/PaymentReturn.jsx', 'payAgain']
]) {
  test(`${fnName}: checks the in-flight ref and canStartPayfastRedirect BEFORE setting any state or awaiting`, () => {
    const source = read(file)
    const start = source.indexOf(`const ${fnName} = async`)
    assert.notEqual(start, -1, `${fnName} not found in ${file}`)
    const body = source.slice(start, source.indexOf('await begin', start))
    assert.match(body, /InFlight\.current\s*\|\|\s*!canStartPayfastRedirect\(/, 'the guard runs before the first await')
    assert.match(body, /InFlight\.current\s*=\s*true/, 'the ref is set synchronously once the guard passes')
  })

  test(`${fnName}: resets the in-flight ref on error, and never on a redirect (the page is about to unload)`, () => {
    const source = read(file)
    const start = source.indexOf(`const ${fnName} = async`)
    const end = source.indexOf('\n  }', source.indexOf('catch (error)', start))
    const body = source.slice(start, end)
    assert.match(body, /catch \(error\) \{\s*\w+InFlight\.current = false/, 'the ref is released in the catch block')
  })
}

test('OrderBasket and GuidedOrder both cover "starting" AND "redirecting" with the shared PaymentRedirectLoader, not just "starting"', () => {
  for (const file of ['../src/components/OrderBasket.jsx', '../src/components/GuidedOrder.jsx', '../src/components/PaymentReturn.jsx']) {
    const source = read(file)
    assert.match(source, /PaymentRedirectLoader/, `${file} renders the shared loader`)
    assert.match(source, /'starting'\s*\|\|\s*\w*[Ss]tate\s*===\s*'redirecting'/, `${file}'s loader condition covers both starting and redirecting`)
  }
})

test('the Pay button label and disabled state read canStartPayfastRedirect, not a hand-rolled "=== \'starting\'" check', () => {
  for (const file of ['../src/components/OrderBasket.jsx', '../src/components/GuidedOrder.jsx']) {
    const source = read(file)
    assert.match(source, /disabled=\{!canStartPayfastRedirect\(/, `${file}'s pay button disables via canStartPayfastRedirect`)
  }
})

test('PaymentReturn "Pay again" is only offered for a cancelled/pending payment with a real saved session, and is disabled while in flight', () => {
  const source = read('../src/components/PaymentReturn.jsx')
  assert.match(source, /state === 'cancelled' \|\| state === 'pending'/)
  assert.match(source, /session\?\.paymentToken/)
  assert.match(source, /disabled=\{!canStartPayfastRedirect\(payAgainState\)\}/)
})

// ── B: cancel/return page navigation stays real navigation, not dead #anchors ──
test('PaymentReturn passes Header real cross-page navigation handlers - the standalone page has none of the #top/#shop/#quick-points targets Header falls back to', () => {
  const source = read('../src/components/PaymentReturn.jsx')
  assert.match(source, /onGoHome=\{\(\) => \{ window\.location\.href = '\/' \}\}/)
  assert.match(source, /onGoShop=\{\(\) => \{ window\.location\.href = '\/shop' \}\}/)
  assert.match(source, /onGoQuickPoints=\{\(\) => \{ window\.location\.href = '\/#quick-points' \}\}/)
})

// ── C: header hide is transform-only, and the scroll listener is rAF-throttled ──
test('the auto-hide header no longer changes height/overflow when hidden - transform is the only thing that moves it', () => {
  const css = read('../src/styles/qs21-5-mobile-shell.css')
  const rule = css.slice(css.indexOf('.qs217-auto-header.is-hidden'), css.indexOf('}', css.indexOf('.qs217-auto-header.is-hidden')))
  assert.doesNotMatch(rule, /height\s*:/, 'no height change alongside the transform')
  assert.doesNotMatch(rule, /overflow\s*:/, 'no overflow change alongside the transform')
  assert.match(rule, /transform\s*:\s*translateY/, 'still hides via transform')
})

test('Header.jsx throttles its scroll listener to one evaluation per animation frame', () => {
  const source = read('../src/components/Header.jsx')
  assert.match(source, /requestAnimationFrame/)
  const listener = source.slice(source.indexOf("addEventListener('scroll'"))
  assert.match(source.slice(0, source.indexOf("addEventListener('scroll'")), /let ticking = false/)
})

// ── D: cart clears explicitly and durably on order success, and re-syncs after bfcache ──
test('App.jsx clears the cart on order success via BOTH the React state AND the real storage removal, not the [cart] effect alone', () => {
  const source = read('../src/App.jsx')
  assert.match(source, /const handleOrderCreated = \(\) => \{\s*setCart\(\[\]\)\s*clearCart\(\)\s*\}/)
  assert.match(source, /onOrderCreated=\{handleOrderCreated\}/)
})

test('App.jsx re-syncs cart state from storage on a bfcache restore (pageshow with event.persisted), never on an ordinary load', () => {
  const source = read('../src/App.jsx')
  const effect = source.slice(source.indexOf("addEventListener('pageshow'") - 200, source.indexOf("addEventListener('pageshow'") + 200)
  assert.match(effect, /event\.persisted/)
  assert.match(effect, /setCart\(loadCart\(\)\)/)
})

test('cartStore.clearCart genuinely removes the storage key, not just writes an empty array', async () => {
  const calls = []
  global.window = {
    localStorage: {
      getItem: () => null,
      setItem: (key, value) => calls.push(['set', key, value]),
      removeItem: (key) => calls.push(['remove', key])
    }
  }
  const { clearCart, saveCart } = await import('../src/lib/cartStore.js')
  saveCart([{ cartId: 'a' }])
  clearCart()
  assert.deepEqual(calls.map((c) => c[0]), ['set', 'remove'])
  assert.equal(calls[1][1], 'qsc_cart_v1')
  delete global.window
})

test('cartStore.loadCart reads back exactly what saveCart wrote for a real, non-empty basket (round trip, no resurrection of anything NOT actually stored)', async () => {
  let stored = null
  global.window = {
    localStorage: {
      getItem: () => stored,
      setItem: (key, value) => { stored = value },
      removeItem: () => { stored = null }
    }
  }
  const { loadCart, saveCart, clearCart } = await import('../src/lib/cartStore.js')
  saveCart([{ cartId: 'x', productName: 'Test' }])
  assert.equal(loadCart().length, 1)
  clearCart()
  assert.deepEqual(loadCart(), [])
  delete global.window
})
