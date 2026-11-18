import test from 'node:test';
import assert from 'node:assert/strict';
import { resolvePayableQr } from '../src/lib/qrPaymentEligibility.js';

const now = Date.parse('2026-10-31T09:00:00Z');
const base = { orderId: 'aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa', state: 'pending', amountCents: 9000, outstandingCents: 9000, currency: 'ZAR', expiresAt: '2026-10-31T10:00:00Z', checkoutUrl: 'https://www.payfast.co.za/eng/process' };
test('only a persisted pending transaction with matching outstanding amount can show QR', () => {
  assert.equal(resolvePayableQr(base, now).ready, true);
  for (const changes of [{ orderId: null }, { state: 'paid' }, { amountCents: 0 }, { amountCents: 9500 }, { outstandingCents: 0 }, { currency: 'USD' }, { expiresAt: '2026-10-31T08:00:00Z' }, { checkoutUrl: 'javascript:alert(1)' }, { checkoutUrl: 'http://example.com/pay' }]) {
    assert.equal(resolvePayableQr({ ...base, ...changes }, now).ready, false, JSON.stringify(changes));
  }
});
