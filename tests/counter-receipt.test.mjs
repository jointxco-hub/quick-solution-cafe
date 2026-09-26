import assert from 'node:assert/strict'
import test from 'node:test'
import fs from 'node:fs'
import { loadCounterUi } from './helpers/counter-ui-harness.mjs'
import { products as seedProducts } from '../src/data/products.js'
import { BUSINESS_ADDRESS_LINES, BUSINESS_CAFE_NAME, WHATSAPP_DISPLAY } from '../src/lib/businessInfo.js'
import { formatMoney } from '../src/lib/pricing.js'
import { loadCounterCatalogueState } from '../src/lib/counterDraft.js'
import { PAYMENT_PHASES, describeCounterOrderDetail, initialPayment } from '../src/lib/counterPayment.js'
import { buildCounterReceipt, counterReceiptBlock, counterReceiptMethodLabel, formatCounterReceiptDate, isCounterReceiptAvailable } from '../src/lib/counterReceipt.js'
import { formatCounterOrderTime } from '../src/lib/counterOrders.js'

// CAFE-GUEST-01R - the paid counter receipt. Read-only: no server change, no migration, no write. The receipt is built
// from the server's order detail (get_quick_solution_counter_order) and rendered by the real components (HTML in plain
// Node, tests/helpers/counter-ui-harness.mjs) with mock data only.

const read = (path) => fs.readFileSync(new URL(path, import.meta.url), 'utf8')
const stripComments = (text) => text.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:'"`])\/\/[^\n]*/g, '$1')
const ui = await loadCounterUi()
const h = ui.React.createElement
const html = (element) => ui.renderToStaticMarkup(element)
const serverProducts = seedProducts.filter((product) => product.channels?.pos === true)
const ready = await loadCounterCatalogueState(async () => ({ tenant: { slug: 'quick-solution', name: 'Quick Solution' }, products: serverProducts }))
const money = (value) => formatMoney(value).replace(/\s/g, '\\s')
const text = (markup) => markup.replace(/<[^>]+>/g, ' ').replace(/&amp;/g, '&').replace(/\s+/g, ' ')

// an order detail exactly as get_quick_solution_counter_order returns it
const unpaid = (overrides = {}) => ({
  orderId: 'b1f0c0de-0000-4000-8000-0000000000aa',
  orderNumber: 'QS-260926-AB12',
  createdAt: '2026-09-26T11:05:00+00:00',
  status: 'submitted',
  paymentStatus: 'unpaid',
  customerName: 'Thandi Nkosi',
  customerEmail: 'thandi@example.com',
  customerPhone: '0751234567',
  subtotal: 35,
  fulfilmentFee: 0,
  totalAmount: 35,
  amountPaid: 0,
  outstanding: 0,
  paymentAllowed: true,
  items: [{ productKey: 'scan', productName: 'Document Scanning', quantity: 1, configuration: { units: 7 }, lineTotal: 35 }],
  payments: [],
  ...overrides
})
const paid = (method = 'cash', overrides = {}) => unpaid({
  paymentStatus: 'paid', amountPaid: 35, outstanding: 0, paymentAllowed: false,
  payments: [{ paymentId: 'pay-00000000-secret-id', method, amount: 35, paidAt: '2026-09-26T11:30:00+00:00' }],
  ...overrides
})
const unpaidDetail = () => unpaid({ outstanding: 35 })

const detailScreen = (order, payment = initialPayment()) => html(h(ui.CounterView, { state: ready, view: 'order', orderDetail: { status: 'ready', order, orderId: order.orderId }, payment }))
const receiptScreen = (order) => html(h(ui.CounterView, { state: ready, view: 'receipt', orderDetail: { status: 'ready', order, orderId: order.orderId } }))
const buttonsOf = (markup) => [...markup.matchAll(/<button[^>]*>([\s\S]*?)<\/button>/g)].map((match) => match[1].replace(/<[^>]+>/g, ''))
const receiptSection = (markup) => markup.slice(markup.indexOf('class="qsc-receipt"'), markup.indexOf('</article>'))

// ── eligibility ─────────────────────────────────────────────────────────
test('only a fully paid order, by the server’s own detail, has a receipt', () => {
  assert.equal(counterReceiptBlock(paid('cash')), null)
  assert.equal(counterReceiptBlock(paid('card')), null)
  assert.equal(counterReceiptBlock(unpaidDetail()), 'not_paid')
  assert.equal(counterReceiptBlock(paid('cash', { outstanding: 5 })), 'outstanding')
  assert.equal(counterReceiptBlock(paid('cash', { amountPaid: 20, payments: [{ method: 'cash', amount: 20, paidAt: '2026-09-26T11:30:00Z' }] })), 'not_fully_paid')
  assert.equal(counterReceiptBlock(paid('cash', { payments: [] })), 'no_payment')
  assert.equal(counterReceiptBlock(paid('cash', { payments: [{ method: 'cash', amount: 0, paidAt: '2026-09-26T11:30:00Z' }] })), 'no_payment')
  assert.equal(counterReceiptBlock(paid('cash', { payments: [{ method: 'cash', amount: 20, paidAt: '2026-09-26T11:30:00Z' }] })), 'payments_inconsistent', 'the ledger must add up to what was paid')
  assert.equal(counterReceiptBlock(paid('cash', { totalAmount: undefined })), 'incomplete')
  assert.equal(counterReceiptBlock(unpaid({ paymentStatus: 'pending' })), 'not_paid')
  assert.equal(counterReceiptBlock(null), 'no_order')
  for (const order of [unpaidDetail(), paid('cash', { outstanding: 5 }), paid('cash', { payments: [] })]) {
    assert.equal(isCounterReceiptAvailable(order), false)
    assert.equal(buildCounterReceipt(order), null)
  }
})

test('an unpaid order has no receipt action; a paid Cash or Card order has View receipt', () => {
  const before = detailScreen(unpaidDetail())
  assert.doesNotMatch(before, /View receipt/)
  assert.deepEqual(buttonsOf(before).filter((label) => /receipt/i.test(label)), [])
  for (const method of ['cash', 'card']) {
    const after = detailScreen(paid(method))
    assert.deepEqual(buttonsOf(after).filter((label) => /receipt/i.test(label)), ['View receipt'], method)
    assert.equal(describeCounterOrderDetail(paid(method)).receiptReady, true)
  }
})

test('the receipt follows the SERVER’s detail, never the screen’s own payment state', () => {
  // the UI just recorded a payment successfully, but the order shown is still the server's unpaid read: no receipt yet
  const success = { phase: PAYMENT_PHASES.SUCCESS, attempt: { orderId: 'x', method: 'cash', amountLabel: formatMoney(35), orderNumber: 'QS-260926-AB12', idempotencyKey: 'k', submissions: 1 }, result: { methodLabel: 'Cash', amountLabel: formatMoney(35), amount: 35, method: 'cash', time: '13:30', orderNumber: 'QS-260926-AB12', replayed: false }, error: null }
  assert.doesNotMatch(detailScreen(unpaidDetail(), success), /View receipt/)
  // and the receipt screen for an order the server does not show as paid says so and offers no Print
  const screen = receiptScreen(unpaidDetail())
  assert.match(screen, /A receipt is available only for a fully paid order\./)
  assert.doesNotMatch(screen, /Print receipt|Payment method|qsc-receipt"/)
  // the page reloads the order from the server when the receipt is opened
  const page = stripComments(read('../src/counter/CounterPage.jsx'))
  assert.match(page, /const openReceipt = \(\) => \{\s*\n\s*if \(!openOrderId\) return\s*\n\s*setView\('receipt'\)\s*\n\s*loadDetail\(openOrderId\)/)
  assert.match(page, /onCloseReceipt=\{\(\) => setView\('order'\)\}/)
  const lib = stripComments(read('../src/lib/counterReceipt.js'))
  assert.doesNotMatch(lib, /payment\.phase|PAYMENT_PHASES|attempt|idempotency|localStorage/)
  // loading and error states
  assert.match(html(h(ui.CounterView, { state: ready, view: 'receipt', orderDetail: { status: 'loading' } })), /Loading the receipt…/)
  assert.match(html(h(ui.CounterView, { state: ready, view: 'receipt', orderDetail: { status: 'error', message: 'Failed to fetch' } })), /Failed to fetch/)
})

// ── content ─────────────────────────────────────────────────────────────
for (const [method, label] of [['cash', 'Cash'], ['card', 'Card']]) {
  test(`a paid ${label} receipt: business, reference, customer, item, totals, payment method, amount and time`, () => {
    const order = paid(method)
    const markup = receiptScreen(order)
    const receipt = text(receiptSection(markup))
    assert.match(receipt, new RegExp(BUSINESS_CAFE_NAME))
    for (const line of BUSINESS_ADDRESS_LINES) assert.match(receipt, new RegExp(line))
    assert.match(receipt, new RegExp(`WhatsApp ${WHATSAPP_DISPLAY.replace(/[+]/g, '\\+')}`))
    assert.match(receipt, /Payment receipt/)
    assert.match(receipt, /Reference QS-260926-AB12/)
    assert.match(receipt, /Thandi Nkosi/)
    assert.match(receipt, /0751234567/)
    assert.match(receipt, /Document Scanning/)
    assert.match(receipt, /7 pages/)
    assert.match(receipt, new RegExp(`Document Scanning[\\s\\S]*${money(35)}`))
    assert.match(receipt, new RegExp(`Subtotal ${money(35)}`))
    assert.match(receipt, new RegExp(`Total ${money(35)}`))
    assert.match(receipt, new RegExp(`Amount paid ${money(35)}`))
    assert.match(receipt, new RegExp(`Outstanding ${money(0)}`), 'a paid receipt shows R0,00 outstanding')
    assert.match(receipt, new RegExp(`Payment method: ${label} ${money(35)}`))
    assert.match(receipt, new RegExp(`${formatCounterReceiptDate('2026-09-26T11:30:00+00:00')} 13:30`), 'the payment time, in the Café’s zone (UTC+2)')
    assert.match(receipt, new RegExp(`Ordered ${formatCounterReceiptDate('2026-09-26T11:05:00+00:00')} 13:05`))
    assert.equal(counterReceiptMethodLabel(method), label)
    const built = buildCounterReceipt(order, ready.entries)
    assert.equal(built.methodSummary, label)
    assert.equal(built.reference, 'QS-260926-AB12')
  })
}

test('a Walk-in customer is shown as Walk-in with no contact lines', () => {
  const markup = receiptScreen(paid('cash', { customerName: 'Walk-in', customerEmail: null, customerPhone: null }))
  assert.match(text(receiptSection(markup)), /Customer Walk-in/)
  assert.doesNotMatch(receiptSection(markup), /<small>[^<]*@/)
  assert.deepEqual(buildCounterReceipt(paid('cash', { customerName: 'Walk-in', customerEmail: null, customerPhone: null })).contact, [])
})

test('the A4 print item reads as a concise job line, from the recorded configuration', () => {
  const order = paid('card', { totalAmount: 72, subtotal: 72, amountPaid: 72, payments: [{ method: 'card', amount: 72, paidAt: '2026-09-26T11:30:00Z' }],
    items: [{ productKey: 'a4-print', productName: 'Document Printing', quantity: 1, configuration: { pages: 12, copies: 3, printMode: 'bw', sides: 'single', finish: 'none', documentInstructions: [{ selection: 'all', sourcePages: 12 }], documentPlanValid: true }, lineTotal: 72 }] })
  const receipt = text(receiptSection(receiptScreen(order)))
  assert.match(receipt, /Document Printing 12 pages × 3 copies/)
  assert.doesNotMatch(receipt, /documentInstructions|sourcePages|documentPlanValid/)
  // an item whose product left the catalogue still gets an honest line from its own configuration, never a guess
  const gone = buildCounterReceipt(paid('cash', { items: [{ productKey: 'retired', productName: 'Retired Thing', quantity: 1, configuration: { units: 3 }, lineTotal: 35 }] }), ready.entries)
  assert.equal(gone.items[0].detail, '3 units')
  assert.equal(buildCounterReceipt(paid('cash', { items: [{ productKey: 'retired', productName: 'Retired Thing', quantity: 1, configuration: { colour: 'red' }, lineTotal: 35 }] }), ready.entries).items[0].detail, null)
})

test('the renderer takes an items array: several items, quantities and a fulfilment fee all render, and nothing assumes one', () => {
  const order = paid('cash', {
    subtotal: 45, fulfilmentFee: 5, totalAmount: 50, amountPaid: 50,
    payments: [{ method: 'cash', amount: 50, paidAt: '2026-09-26T11:30:00Z' }],
    items: [
      { productKey: 'scan', productName: 'Document Scanning', quantity: 1, configuration: { units: 3 }, lineTotal: 15 },
      { productKey: 'a4-lamination', productName: 'A4 Lamination', quantity: 1, configuration: { units: 2 }, lineTotal: 30 },
      { productKey: 'flags', productName: 'Flag', quantity: 2, configuration: {}, lineTotal: 0 }
    ]
  })
  const built = buildCounterReceipt(order, ready.entries)
  assert.deepEqual(built.items.map((item) => [item.name, item.quantity]), [['Document Scanning', 1], ['A4 Lamination', 1], ['Flag', 2]])
  const receipt = text(receiptSection(receiptScreen(order)))
  assert.match(receipt, new RegExp(`Document Scanning 3 pages ${money(15)}`))
  assert.match(receipt, new RegExp(`A4 Lamination 2 sheets ${money(30)}`))
  assert.match(receipt, /Flag Qty 2/)
  assert.match(receipt, new RegExp(`Subtotal ${money(45)} Fulfilment fee ${money(5)} Total ${money(50)}`))
  // zero fee is not printed; no items still renders
  assert.equal(buildCounterReceipt(paid('cash')).fulfilmentFee, null)
  assert.doesNotMatch(receiptSection(receiptScreen(paid('cash'))), /Fulfilment fee/)
  assert.equal(buildCounterReceipt(paid('cash', { items: [] })).items.length, 0)
  assert.doesNotMatch(stripComments(read('../src/lib/counterReceipt.js')), /items\[0\]|items\.at\(0\)|\.items\.length\s*===\s*1/)
})

test('several completed payments render safely (legacy or gateway rows), never assuming one', () => {
  const order = paid('cash', { payments: [
    { method: 'payfast', amount: 20, paidAt: '2026-09-26T10:00:00Z' },
    { method: 'cash', amount: 15, paidAt: '2026-09-26T11:30:00Z' }
  ] })
  assert.equal(counterReceiptBlock(order), null)
  const built = buildCounterReceipt(order)
  assert.equal(built.payments.length, 2)
  assert.equal(built.methodSummary, 'PayFast (online) + Cash')
  assert.equal(built.paidTime, formatCounterOrderTime('2026-09-26T11:30:00Z'), 'the paid time is the last payment')
  const receipt = text(receiptSection(receiptScreen(order)))
  assert.match(receipt, new RegExp(`Payment method: PayFast \\(online\\) ${money(20)}`))
  assert.match(receipt, new RegExp(`Payment method: Cash ${money(15)}`))
  assert.doesNotMatch(receipt, /EFT|bank transfer|card number/i)
})

// ── money, dates, identity ──────────────────────────────────────────────
test('money, dates and identity come from the established sources - nothing hand-formatted or hard-coded', () => {
  const lib = stripComments(read('../src/lib/counterReceipt.js'))
  assert.match(lib, /import \{ formatMoney \} from '\.\/pricing\.js'/)
  assert.doesNotMatch(lib, /toFixed|NumberFormat|['"`]R\s|currency|toLocale/, 'no second currency formatter')
  assert.match(lib, /COUNTER_ORDERS_TIMEZONE/)
  assert.doesNotMatch(lib + stripComments(read('../src/counter/CounterView.jsx')), /Kite Cres|Riverside View|27693505865|\+27 69|Joint X Quick Solution|['"]Africa\/Johannesburg['"]/, 'business details and the zone come from their sources')
  assert.match(lib, /from '\.\/businessInfo\.js'/)
  assert.match(read('../src/lib/businessInfo.js'), /export const BUSINESS_CAFE_NAME = /)
  // the sale reference is the existing order number; no receipt number is invented
  assert.doesNotMatch(lib, /receiptNumber|receipt_number|sequence|nextval|randomUUID|Math\.random/i)
  assert.equal(buildCounterReceipt(paid('cash')).reference, paid('cash').orderNumber)
  // no tax claims are made
  assert.doesNotMatch(text(receiptScreen(paid('cash'))), /VAT|tax invoice|tax/i)
  // 21:59 UTC and 22:00 UTC fall on different Johannesburg days
  assert.notEqual(formatCounterReceiptDate('2026-09-26T21:59:00Z'), formatCounterReceiptDate('2026-09-26T22:00:00Z'))
  assert.equal(formatCounterReceiptDate('nonsense'), '—')
})

// ── privacy ─────────────────────────────────────────────────────────────
test('nothing internal can reach the receipt, even if it were present in the data', () => {
  const leaky = paid('card', {
    idempotencyKey: 'LEAK-ORDER-KEY', idempotency_key: 'LEAK-KEY-2', createdBy: 'LEAK-ACTOR', recordedBy: 'LEAK-RECORDER', sourceMetadata: { secret: 'LEAK-META' },
    pricingSnapshot: { cost: 'LEAK-COST' }, pricing_definition: 'LEAK-DEF', supplierCost: 'LEAK-SUPPLIER', margin: 'LEAK-MARGIN', tenantId: 'LEAK-TENANT', channel: 'counter'
  })
  leaky.items[0].pricing_snapshot = 'LEAK-ITEM-SNAPSHOT'
  leaky.payments[0].recordedBy = 'LEAK-PAYMENT-ACTOR'
  leaky.payments[0].idempotencyKey = 'LEAK-PAYMENT-KEY'
  const built = buildCounterReceipt(leaky, ready.entries)
  assert.deepEqual(Object.keys(built).sort(), ['amountPaid', 'business', 'contact', 'customer', 'fulfilmentFee', 'items', 'methodSummary', 'orderDate', 'orderTime', 'outstanding', 'paidDate', 'paidTime', 'payments', 'reference', 'subtotal', 'title', 'total'])
  const everything = JSON.stringify(built) + receiptScreen(leaky)
  assert.doesNotMatch(everything, /LEAK-|pay-00000000-secret-id|b1f0c0de|idempotency|counter-payment|pricing|supplier|margin|source_?metadata|tenant/i)
  assert.deepEqual(Object.keys(built.payments[0]).sort(), ['amount', 'date', 'method', 'methodLabel', 'paidAt', 'time'])
  assert.deepEqual(Object.keys(built.items[0]).sort(), ['detail', 'lineTotal', 'name', 'quantity'])
  assert.doesNotMatch(receiptScreen(paid('card')), /card number|last four|cardholder|terminal|expiry|cvv/i, 'no card data exists to print')
})

// ── controls ────────────────────────────────────────────────────────────
test('the receipt screen offers Back to order and Print receipt - no refund, void, email, WhatsApp, EFT or editing', () => {
  const markup = receiptScreen(paid('cash'))
  assert.deepEqual(buttonsOf(markup), ['Sign out', '← Back to order', 'Print receipt'])
  assert.doesNotMatch(markup.slice(markup.indexOf('qsc-receipt-screen')), /<input|<select|<textarea|type="number"|<a /i, 'nothing to edit, no links out')
  assert.doesNotMatch(text(markup), /Refund|Void|Email|WhatsApp receipt|Send|Reprint|EFT|Edit|Record (Cash|Card)/i)
  assert.doesNotMatch(markup, /qsc-tabs/, 'the counter tabs are not part of the receipt screen')
  const source = stripComments(read('../src/counter/CounterView.jsx') + read('../src/counter/CounterPage.jsx') + read('../src/lib/counterReceipt.js'))
  assert.doesNotMatch(source, /refund|voidOrder|emailReceipt|sendReceipt|shareReceipt|whatsappReceipt|mailto:|wa\.me\/|reprint|\beft\b/i)
  // paying is not possible from the receipt, and a paid order's detail offers no payment either
  assert.doesNotMatch(detailScreen(paid('cash')), /Record (Cash|Card) Payment/)
})

// ── printing ────────────────────────────────────────────────────────────
test('Print receipt is the browser’s own print, with no printer bridge and no new infrastructure', () => {
  const page = stripComments(read('../src/counter/CounterPage.jsx'))
  assert.match(page, /onPrintReceipt=\{\(\) => window\.print\(\)\}/)
  assert.equal((page.match(/window\.print/g) || []).length, 1)
  for (const file of ['../src/counter/CounterPage.jsx', '../src/counter/CounterView.jsx', '../src/lib/counterReceipt.js']) {
    assert.doesNotMatch(stripComments(read(file)), /imin|printer|bridge|AndroidPrinter|sendText|printText|escpos|bluetooth|navigator\./i, file)
  }
  assert.match(receiptScreen(paid('cash')), /<button[^>]*class="button dark qsc-action qsc-print"[^>]*>Print receipt<\/button>/)
})

test('the print stylesheet prints only the receipt, in one narrow column that also fits a normal page', () => {
  const css = read('../src/styles/qs-counter.css')
  const start = css.indexOf('@media print{')
  assert.ok(start > 0, 'a print media block exists')
  const block = css.slice(start)
  for (const hidden of ['.qsc-bar', '.qsc-tabs', '.qsc-receipt-actions', '.qsc-back', '.qsc-print']) {
    assert.ok(block.includes(hidden), `${hidden} is hidden in print`)
  }
  assert.match(block, /\.qsc-bar,\.qsc-tabs,\.qsc-receipt-actions,\.qsc-back,\.qsc-print[^{]*\{display:none !important\}/)
  assert.match(block, /@page\{margin:6mm\}/)
  assert.match(block, /\.qsc-receipt\{width:min\(100%,88mm\);max-width:88mm;/, 'about 80 mm paper: narrow POS and a column on A4')
  assert.match(block, /border:0/)
  assert.match(css, /\.qsc-receipt\{width:min\(100%,420px\)/, 'on screen it is the same narrow column')
  // everything printable is inside the receipt: the print block only hides chrome, and the screen has no other content
  const markup = receiptScreen(paid('card'))
  const outside = markup.slice(0, markup.indexOf('class="qsc-receipt"'))
  for (const chrome of ['qsc-bar', 'qsc-receipt-actions']) assert.match(outside, new RegExp(chrome))
  assert.match(css, /html,body\{background:#fff !important\}/)
})

// ── scope ───────────────────────────────────────────────────────────────
test('nothing is written and no server change was needed: no migration, no API call, no new RPC', () => {
  const lib = stripComments(read('../src/lib/counterReceipt.js'))
  assert.doesNotMatch(lib, /supabaseApi|\bfetch\s*\(|\brpc\s*\(|localStorage|sessionStorage|XMLHttpRequest/)
  const migrations = fs.readdirSync(new URL('../supabase/migrations/', import.meta.url)).filter((name) => name.endsWith('.sql')).sort()
  assert.equal(migrations.some((name) => /receipt/i.test(name)), false, 'the receipt needed no migration of its own')
  assert.ok(migrations.includes('20260926240000_cafe_guest_01q_counter_order_detail_and_payment.sql'))
  const api = read('../src/lib/supabaseApi.js')
  assert.doesNotMatch(api, /receipt/i, 'no receipt API wrapper')
  const page = stripComments(read('../src/counter/CounterPage.jsx'))
  const imported = read('../src/counter/CounterPage.jsx').match(/import \{([^}]*)\} from '\.\.\/lib\/supabaseApi\.js'/)[1].split(',').map((name) => name.trim()).filter(Boolean)
  assert.deepEqual(imported, ['cancelQuickSolutionCounterOrder', 'createQuickSolutionCounterOrder', 'getAdminSession', 'loadQuickSolutionCancelledCounterOrders', 'loadQuickSolutionCounterCashup', 'loadQuickSolutionCounterCashupToday', 'loadQuickSolutionCounterCatalog', 'loadQuickSolutionCounterOrder', 'loadQuickSolutionCounterOrderCancelCheck', 'loadQuickSolutionCounterOrdersToday', 'loadQuickSolutionUnpaidCounterOrders', 'recordQuickSolutionCounterPayment', 'signInAdmin', 'signOutAdmin'], 'the same API calls as before 01R')
  assert.equal((page.match(/recordQuickSolutionCounterPayment/g) || []).length, 2, 'the payment call is untouched: imported once, used once')
})

test('the new test file is part of npm test', () => {
  assert.match(JSON.parse(read('../package.json')).scripts.test, /tests\/counter-receipt\.test\.mjs/)
})

test('one unit reads as singular on the receipt (1 sheet, 1 page), several as plural', () => {
  const one = buildCounterReceipt(paid('cash', { items: [{ productKey: 'a3-lamination', productName: 'A3 Lamination', quantity: 1, configuration: { units: 1 }, lineTotal: 35 }] }), ready.entries)
  assert.equal(one.items[0].detail, '1 sheet')
  const scan = buildCounterReceipt(paid('cash', { items: [{ productKey: 'scan', productName: 'Document Scanning', quantity: 1, configuration: { units: 1 }, lineTotal: 35 }] }), ready.entries)
  assert.equal(scan.items[0].detail, '1 page')
  const many = buildCounterReceipt(paid('cash', { items: [{ productKey: 'a3-lamination', productName: 'A3 Lamination', quantity: 1, configuration: { units: 2 }, lineTotal: 35 }] }), ready.entries)
  assert.equal(many.items[0].detail, '2 sheets')
})
