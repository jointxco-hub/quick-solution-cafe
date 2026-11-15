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


// Same-browser checkout fallback. Only reads this storefront's existing
// first-party tracking session; never creates a token or skips backend checks.
export function findQuickSolutionTrackingSessionByOrderNumber(orderNumber) {
  const target = String(orderNumber || '').trim().toUpperCase()
  const store = storage()
  if (!target || !store) return null
  try {
    for (let i = 0; i < store.length; i += 1) {
      const key = store.key(i)
      if (!key?.startsWith(PREFIX)) continue
      let value = null
      try { value = JSON.parse(store.getItem(key) || 'null') } catch { continue }
      if (!value?.trackingToken || String(value.orderNumber || '').trim().toUpperCase() !== target) continue
      const expiration = Date.parse(String(value.trackingTokenExpiresAt || ''))
      if (Number.isFinite(expiration) && expiration <= Date.now()) continue
      return value
    }
  } catch { return null }
  return null
}
