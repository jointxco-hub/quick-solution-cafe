import test from 'node:test'
import assert from 'node:assert/strict'
import { orderDay, filterOrders } from '../src/admin/orderOverview.js'
test('today follows Johannesburg midnight rather than UTC or device timezone', () => {
  const orders = [{ submittedAt: '2026-10-05T21:59:00Z' }, { submittedAt: '2026-10-05T22:00:00Z' }]
  assert.deepEqual(filterOrders(orders, 'today', new Date('2026-10-06T01:00:00Z')), [orders[1]])
  assert.equal(orderDay('invalid'), '')
})
test('attention includes failed sends; all orders sort newest first without mutating the queue', () => {
  const orders = [{ submittedAt: '2026-10-01', handoffStatus: 'failed' }, { submittedAt: '2026-10-03', handoffStatus: 'ready' }, { submittedAt: '2026-10-02', handoffStatus: 'blocked' }]
  assert.deepEqual(filterOrders(orders, 'attention'), [orders[2], orders[0]])
  assert.deepEqual(filterOrders(orders, 'all'), [orders[1], orders[2], orders[0]])
  assert.equal(orders[0].handoffStatus, 'failed')
})
