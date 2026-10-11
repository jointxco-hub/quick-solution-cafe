import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import vm from 'node:vm'
import { readStaffOrderId, counterNotificationAdminFallback } from '../src/lib/staffNotificationNavigation.js'
const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8')
function worker(clients = []) {
 const handlers = {}, notices = [], opened = []
 const self = { location: { origin: 'https://cafe.example' }, addEventListener: (name, cb) => { handlers[name] = cb }, registration: { showNotification: async (...args) => { notices.push(args) } }, clients: { matchAll: async () => clients, openWindow: async (url) => { opened.push(url) } } }
 vm.runInNewContext(read('public/staff-sw.js'), { self, URL })
 return { handlers, notices, opened }
}
test('both installed apps have different identities and launch directly into their staff route', () => {
 const admin = JSON.parse(read('public/staff-admin.webmanifest')), counter = JSON.parse(read('public/staff-counter.webmanifest'))
 assert.notEqual(admin.id, counter.id)
 assert.equal(admin.start_url, '/admin'); assert.equal(counter.start_url, '/counter')
 for (const manifest of [admin,counter]) { assert.equal(manifest.display, 'standalone'); assert.ok(manifest.icons.some((icon) => icon.sizes === '512x512')) }
})
test('malformed push data still produces a visible generic alert', async () => {
 const { handlers, notices } = worker(); let pending
 handlers.push({ data: { json() { throw new Error('malformed') } }, waitUntil(promise) { pending=promise } })
 await pending; assert.equal(notices.length,1); assert.equal(notices[0][0],'Café update')
})
test('an injected external notification URL cannot navigate staff away from the café app', async () => {
 const { handlers, opened } = worker(); let pending
 handlers.notificationclick({ notification: { data: { app: 'counter', url: 'https://evil.example/phishing' }, close() {} }, waitUntil(promise) { pending=promise } })
 await pending; assert.deepEqual(opened,['https://cafe.example/counter'])
})
test('admin notifications open the admin screen', async () => {
 const { handlers, opened } = worker(); let pending
 handlers.notificationclick({ notification: { data: { app: 'admin' }, close() {} }, waitUntil(promise) { pending=promise } })
 await pending; assert.deepEqual(opened,['https://cafe.example/admin'])
})

const ORDER_ID = 'd3011e42-d7e5-42a9-82d3-8b8f15d1c260'
async function pushEvent(w, payload) {
 let pending
 w.handlers.push({ data: { json: () => payload }, waitUntil(promise) { pending = promise } })
 await pending
 return w.notices[0][1].data
}
async function clickEvent(w, data) {
 let pending
 w.handlers.notificationclick({ notification: { data, close() {} }, waitUntil(promise) { pending = promise } })
 await pending
}
test('new, paid and ready order alerts carry the order ID through to either staff route', async () => {
 for (const app of ['admin', 'counter']) for (const event of ['new', 'paid', 'ready']) {
  const w = worker()
  const data = await pushEvent(w, { app, tag: `${ORDER_ID}:${event}` })
  assert.equal(data.orderId, ORDER_ID)
  await clickEvent(w, data)
  assert.deepEqual(w.opened, [`https://cafe.example/${app}?order=${ORDER_ID}`])
 }
})
test('an existing staff window navigates to the notified order before focusing', async () => {
 const steps = []
 const w = worker([{ url: 'https://cafe.example/admin?order=old', navigate: async (url) => {
  steps.push(url)
  return { focus: async () => { steps.push('focus') } }
 }, focus: async () => { throw new Error('must navigate first') } }])
 await clickEvent(w, { app: 'admin', orderId: ORDER_ID })
 assert.deepEqual(steps, [`https://cafe.example/admin?order=${ORDER_ID}`, 'focus'])
 assert.equal(w.opened.length, 0)
})
test('failed existing-window navigation opens the requested order in a new window', async () => {
 const w = worker([{ url: 'https://cafe.example/counter', navigate: async () => { throw new Error('closed') } }])
 await clickEvent(w, { app: 'counter', orderId: ORDER_ID })
 assert.deepEqual(w.opened, [`https://cafe.example/counter?order=${ORDER_ID}`])
})
test('test alerts have no order target and malformed order IDs cannot inject routes', async () => {
 const w = worker()
 assert.equal((await pushEvent(w, { app: 'counter', tag: 'cafe-test' })).orderId, null)
 await clickEvent(w, { app: 'admin', orderId: '../?redirect=https://evil.example' })
 assert.deepEqual(w.opened, ['https://cafe.example/admin'])
 assert.equal(readStaffOrderId(`?order=${ORDER_ID}`), ORDER_ID)
 assert.equal(readStaffOrderId('?order=bad'), '')
 assert.equal(readStaffOrderId(''), '')
})

test('only a missing notified Counter order falls back to its Admin detail, never an access denial or another selection', () => {
 const search = `?order=${ORDER_ID}`
 assert.equal(counterNotificationAdminFallback('not-found', ORDER_ID, search), `/admin?order=${ORDER_ID}`)
 for (const status of ['denied', 'signed-out', 'error', 'unavailable', 'ready']) {
  assert.equal(counterNotificationAdminFallback(status, ORDER_ID, search), null)
 }
 assert.equal(counterNotificationAdminFallback('not-found', ORDER_ID, ''), null)
 assert.equal(counterNotificationAdminFallback('not-found', '00000000-0000-0000-0000-000000000000', search), null)
})

test('Counter and Admin select the same installable Café manifest', () => {
 const manifest = JSON.parse(read('public/staff-cafe.webmanifest'))
 assert.equal(manifest.id, '/staff-admin')
 assert.equal(manifest.name, 'Quick Solution Café')
 assert.equal(manifest.scope, '/')
 assert.equal(manifest.start_url, '/counter')
 assert.deepEqual(manifest.shortcuts.map((item) => item.url), ['/counter', '/admin'])
 assert.ok(read('src/lib/staffPwa.js').includes('manifest.href = "/staff-cafe.webmanifest"'))
})
test('an order notification switches the existing Café window from Counter to Admin', async () => {
 const navigated = [], focused = []
 const client = { url: 'https://cafe.example/counter', async navigate(url) { navigated.push(url); return { async focus() { focused.push(url) } } } }
 const w = worker([client])
 await clickEvent(w, { app: 'admin', orderId: ORDER_ID })
 assert.deepEqual(navigated, [`https://cafe.example/admin?order=${ORDER_ID}`])
 assert.equal(focused.length, 1)
 assert.equal(w.opened.length, 0)
})
test('a generic notification switches the existing Café window to the requested workspace', async () => {
 const navigated = []
 const client = { url: 'https://cafe.example/admin', async navigate(url) { navigated.push(url); return { async focus() {} } } }
 const w = worker([client])
 await clickEvent(w, { app: 'counter' })
 assert.deepEqual(navigated, ['https://cafe.example/counter'])
 assert.equal(w.opened.length, 0)
})
