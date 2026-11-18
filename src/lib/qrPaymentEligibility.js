// QR payment presentation gate. The backend owns the payment request, price,
// tenant, expiry and PayFast confirmation. Never derive a payable QR from a basket estimate.
const uuid = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i;

export function resolvePayableQr(request, now = Date.now()) {
  if (!request || !uuid.test(String(request.orderId || ''))) return { ready: false, reason: 'Save the order first.' };
  if (request.state !== 'pending') return { ready: false, reason: 'Payment request is not pending.' };
  if (!Number.isSafeInteger(request.amountCents) || request.amountCents <= 0 || request.currency !== 'ZAR') {
    return { ready: false, reason: 'Payment amount is invalid.' };
  }
  if (!Number.isSafeInteger(request.outstandingCents) || request.outstandingCents !== request.amountCents) {
    return { ready: false, reason: 'Refresh the payment request to match the outstanding balance.' };
  }
  const expires = Date.parse(request.expiresAt);
  if (!Number.isFinite(expires) || expires <= now) return { ready: false, reason: 'Payment request has expired.' };
  if (typeof request.checkoutUrl !== 'string') return { ready: false, reason: 'Checkout is unavailable.' };
  let checkout;
  try { checkout = new URL(request.checkoutUrl); } catch { return { ready: false, reason: 'Checkout is unavailable.' }; }
  if (checkout.protocol !== 'https:' || checkout.username || checkout.password || !checkout.hostname) {
    return { ready: false, reason: 'Checkout is unavailable.' };
  }
  // The server must generate the URL and independently authorize the tenant and transaction.
  return { ready: true, url: checkout.href, expiresAt: request.expiresAt, amountCents: request.amountCents };
}
