const PREFIX = 'qsc_payment_session_v1:'

function storage() {
  if (typeof window === 'undefined') return null
  return window.localStorage
}

export function saveQuickSolutionPaymentSession(session) {
  if (!session?.orderId || !session?.paymentToken) return
  const payload = {
    orderId: String(session.orderId),
    paymentToken: String(session.paymentToken),
    orderNumber: String(session.orderNumber || ''),
    amount: Number(session.amount || 0),
    savedAt: new Date().toISOString()
  }
  storage()?.setItem(`${PREFIX}${payload.orderId}`, JSON.stringify(payload))
}

export function readQuickSolutionPaymentSession(orderId) {
  if (!orderId) return null
  try {
    const raw = storage()?.getItem(`${PREFIX}${orderId}`)
    return raw ? JSON.parse(raw) : null
  } catch {
    return null
  }
}

export function clearQuickSolutionPaymentSession(orderId) {
  if (!orderId) return
  storage()?.removeItem(`${PREFIX}${orderId}`)
}
