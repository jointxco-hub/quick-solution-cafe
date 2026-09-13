const PREFIX = 'qsc_tracking_session_v1:'

function storage() {
  if (typeof window === 'undefined') return null
  return window.localStorage
}

export function saveQuickSolutionTrackingSession(session) {
  if (!session?.orderId || !session?.orderNumber || !session?.trackingToken) return
  const payload = {
    orderId: String(session.orderId),
    orderNumber: String(session.orderNumber),
    trackingToken: String(session.trackingToken),
    trackingTokenExpiresAt: String(session.trackingTokenExpiresAt || ''),
    savedAt: new Date().toISOString()
  }
  storage()?.setItem(`${PREFIX}${payload.orderId}`, JSON.stringify(payload))
}

export function readQuickSolutionTrackingSession(orderId) {
  if (!orderId) return null
  try {
    const raw = storage()?.getItem(`${PREFIX}${orderId}`)
    return raw ? JSON.parse(raw) : null
  } catch {
    return null
  }
}

export function buildQuickSolutionTrackingHref(orderNumber, trackingToken) {
  if (!orderNumber || !trackingToken) return '/track'
  const params = new URLSearchParams({
    order: String(orderNumber),
    token: String(trackingToken)
  })
  return `/track?${params.toString()}`
}
