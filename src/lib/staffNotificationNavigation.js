// Notification links select an order; every read still goes through the authorized server API.
export function readStaffOrderId(search = typeof window === 'undefined' ? '' : window.location.search) {
  const id = new URLSearchParams(search).get('order') || ''
  return /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i.test(id) ? id : ''
}

export function counterNotificationAdminFallback(status, orderId, search) {
  // Counter cannot display every storefront order. Try the normal Admin read;
  // a missing Counter order is never treated as proof of Admin permission.
  return status === 'not-found' && orderId && readStaffOrderId(search) === orderId
    ? `/admin?order=${orderId}`
    : null
}
