import { createCustomerClient } from './customerClient.js'

let client
export function customerClient() {
  if (!client) client = createCustomerClient({
    url: String(import.meta.env.VITE_SUPABASE_URL || '').replace(/\/$/, ''),
    key: String(import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY || import.meta.env.VITE_SUPABASE_ANON_KEY || ''),
    storage: window.localStorage, location: window.location, history: window.history
  })
  return client
}

export function readRecoverableOrders(storage = window.localStorage) {
  const orders = new Map()
  for (let i = 0; i < storage.length; i += 1) {
    const key = storage.key(i)
    if (!key?.startsWith('qsc_payment_session_v1:') && !key?.startsWith('qsc_tracking_session_v1:')) continue
    try {
      const item = JSON.parse(storage.getItem(key))
      const token = item.paymentToken || item.trackingToken
      if (item.orderId && item.orderNumber && token) orders.set(item.orderId, { orderId: item.orderId, orderNumber: item.orderNumber, token })
    } catch { /* Ignore incomplete local sessions. */ }
  }
  return [...orders.values()]
}
