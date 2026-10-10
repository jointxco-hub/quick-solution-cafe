export function staffAppKind(pathname = window.location.pathname, hash = window.location.hash) {
  if (pathname.replace(/\/+$/, '') === '/counter') return 'counter'
  if (pathname.replace(/\/+$/, '') === '/admin' || hash === '#admin') return 'admin'
  return null
}

let registrationPromise
let installEvent
if (typeof window !== 'undefined') window.addEventListener('beforeinstallprompt', (event) => {
  if (!staffAppKind()) return
  event.preventDefault()
  installEvent = event
  window.dispatchEvent(new Event('qs-install-ready'))
})

export function canPromptInstall() { return Boolean(installEvent) }
export async function promptInstall() {
  if (!installEvent) return false
  const event = installEvent
  installEvent = null
  await event.prompt()
  return (await event.userChoice).outcome === 'accepted'
}

export function registerStaffWorker() {
  if (!('serviceWorker' in navigator) || !window.isSecureContext) return Promise.reject(new Error('Use HTTPS to install the café app.'))
  registrationPromise ||= navigator.serviceWorker.register('/staff-sw.js', { scope: '/', updateViaCache: 'none' }).then(() => navigator.serviceWorker.ready)
  return registrationPromise
}

export function setupStaffPwa() {
  const kind = staffAppKind()
  if (!kind) return
  const manifest = document.createElement('link')
  manifest.rel = 'manifest'
  manifest.href = "/staff-cafe.webmanifest"
  document.head.appendChild(manifest)
  const title = 'Quick Solution Café'
  document.title = title
  const appleIcon = document.querySelector('link[rel="apple-touch-icon"]')
  if (appleIcon) appleIcon.href = '/staff-admin-192.png'
  for (const [name, content] of [['apple-mobile-web-app-capable', 'yes'], ['apple-mobile-web-app-title', title]]) {
    const meta = document.createElement('meta'); meta.name = name; meta.content = content; document.head.appendChild(meta)
  }
  registerStaffWorker().catch(() => {})
}

export function decodeApplicationKey(value) {
  const base64 = value.replace(/-/g, '+').replace(/_/g, '/')
  return Uint8Array.from(atob(base64), (character) => character.charCodeAt(0))
}
