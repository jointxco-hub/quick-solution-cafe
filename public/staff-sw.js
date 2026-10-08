// Network-only worker: never cache staff sessions, prices, orders or payments.
self.addEventListener('install', () => self.skipWaiting())
self.addEventListener('activate', (event) => event.waitUntil(self.clients.claim()))
self.addEventListener('push', (event) => {
  let payload = {}
  try { payload = event.data?.json() || {} } catch { /* Always display a generic notification. */ }
  const app = payload.app === 'counter' ? 'counter' : 'admin'
  event.waitUntil(self.registration.showNotification(payload.title || 'Café update', {
    body: payload.body || 'Open the café app to review.',
    icon: `/staff-${app}-192.png`,
    badge: '/staff-badge.png',
    tag: payload.tag || 'cafe-update',
    data: { url: `/${app}`, app },
  }))
})
self.addEventListener('notificationclick', (event) => {
  event.notification.close()
  const path = event.notification.data?.app === 'counter' ? '/counter' : '/admin'
  const target = new URL(path, self.location.origin).href
  event.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true }).then(async (clients) => {
    const existing = clients.find((client) => new URL(client.url).pathname === path)
    if (existing) return existing.focus()
    return self.clients.openWindow(target)
  }))
})
