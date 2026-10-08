import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import vm from 'node:vm'
const read = (path) => readFileSync(new URL(`../${path}`, import.meta.url), 'utf8')
function worker() {
 const handlers = {}, notices = [], opened = []
 const self = { location: { origin: 'https://cafe.example' }, addEventListener: (name, cb) => { handlers[name] = cb }, registration: { showNotification: async (...args) => { notices.push(args) } }, clients: { matchAll: async () => [], openWindow: async (url) => { opened.push(url) } } }
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
