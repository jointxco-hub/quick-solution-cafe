import test from 'node:test'
import assert from 'node:assert/strict'
import { createCustomerClient, CUSTOMER_SESSION_KEY, parseGuestTrackingLink } from '../src/lib/customerClient.js'

function fixture(respond = () => ({})) {
  const values = new Map([['qsc_admin_session_v1', 'staff-session']])
  const storage = { getItem: key => values.get(key), setItem: (key, value) => values.set(key, value), removeItem: key => values.delete(key) }
  const calls = []; const history = { replaceState: (...args) => calls.push(['history', ...args]) }
  const location = { origin: 'https://cafe.example', hash: '' }
  const client = createCustomerClient({ url: 'https://db.example', key: 'public-key', storage, location, history, now: () => 100000,
    fetcher: async (url, options) => { calls.push([url, options]); return { ok: true, json: async () => respond(url, options) } } })
  return { client, values, calls, location }
}
test('guest checkout has no customer authorization and does not use staff credentials', async () => {
  const f = fixture()
  assert.deepEqual(await f.client.checkoutContext(), { accessToken: null, email: null })
  assert.equal(f.calls.length, 0)
  assert.equal(f.values.get('qsc_admin_session_v1'), 'staff-session')
})
test('guest recovery parses only a complete tracking link and never navigates to input', () => {
  const token = 'a'.repeat(64)
  assert.deepEqual(parseGuestTrackingLink(`https://cafe.example/track?order=QS-TEST&token=${token}`), { orderNumber: 'QS-TEST', trackingToken: token })
  for (const value of ['javascript:alert(1)', 'QS-TEST', 'https://cafe.example/track?order=QS-TEST', `https://cafe.example/admin?order=QS-TEST&token=${token}`]) assert.equal(parseGuestTrackingLink(value), null)
})
test('sign-in email uses this origin account callback and creates a customer auth user', async () => {
  const f = fixture()
  await f.client.sendLink(' person@example.com ')
  assert.equal(f.calls[0][0], 'https://db.example/auth/v1/otp?redirect_to=https%3A%2F%2Fcafe.example%2Faccount')
  assert.deepEqual(JSON.parse(f.calls[0][1].body), { email: 'person@example.com', create_user: true })
})
test('callback removes credentials from browser history and stores only customer session', () => {
  const f = fixture(); f.location.hash = '#access_token=customer&refresh_token=refresh&expires_in=3600'
  f.client.consumeRedirect()
  assert.equal(JSON.parse(f.values.get(CUSTOMER_SESSION_KEY)).access_token, 'customer')
  assert.equal(f.values.get('qsc_admin_session_v1'), 'staff-session')
  assert.deepEqual(f.calls[0], ['history', null, '', '/account'])
})
test('malformed callback still scrubs fragment and stores no credentials', () => {
  const f = fixture(); f.location.hash = '#access_token=incomplete'
  assert.throws(() => f.client.consumeRedirect(), /valid session/)
  assert.equal(f.values.has(CUSTOMER_SESSION_KEY), false)
  assert.deepEqual(f.calls[0], ['history', null, '', '/account'])
})
test('simultaneous requests refresh once and share the rotated customer session', async () => {
  const f = fixture(url => url.includes('/token') ? { access_token: 'new', refresh_token: 'new-refresh', expires_in: 3600 } : { orders: [] })
  f.values.set(CUSTOMER_SESSION_KEY, JSON.stringify({ access_token: 'old', refresh_token: 'old-refresh', expiresAt: 0 }))
  await Promise.all([f.client.rpc('qs_customer_orders', {}), f.client.rpc('qs_customer_orders', {})])
  assert.equal(f.calls.filter(([url]) => url.includes('/token')).length, 1)
  for (const [, options] of f.calls.filter(([url]) => url.includes('/rpc/'))) assert.equal(options.headers.Authorization, 'Bearer new')
})
test('sign-out revokes only customer session and preserves staff session', async () => {
  const f = fixture()
  f.values.set(CUSTOMER_SESSION_KEY, JSON.stringify({ access_token: 'customer', refresh_token: 'refresh', expiresAt: 900000 }))
  await f.client.signOut()
  assert.equal(f.calls[0][0], 'https://db.example/auth/v1/logout?scope=local')
  assert.equal(f.calls[0][1].headers.Authorization, 'Bearer customer')
  assert.equal(f.values.has(CUSTOMER_SESSION_KEY), false)
  assert.equal(f.values.get('qsc_admin_session_v1'), 'staff-session')
})
