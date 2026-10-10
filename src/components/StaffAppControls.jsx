import React, { useEffect, useState } from 'react'
import { canPromptInstall, decodeApplicationKey, promptInstall, registerStaffWorker } from '../lib/staffPwa.js'
import { staffPushRequest } from '../lib/supabaseApi.js'
import '../styles/staff-app.css'

export default function StaffAppControls({ app, signedIn = true }) {
  // This app is client-rendered; node-only counter markup tests have no install surface.
  if (typeof window === 'undefined') return null
  const [installReady, setInstallReady] = useState(canPromptInstall)
  const [enabled, setEnabled] = useState(false)
  const [busy, setBusy] = useState(false)
  const [message, setMessage] = useState('')
  const browser = typeof window !== 'undefined'
  const standalone = browser && (window.matchMedia('(display-mode: standalone)').matches || navigator.standalone)
  const supported = browser && 'PushManager' in window && 'Notification' in window && 'serviceWorker' in navigator
  useEffect(() => {
    if (!browser) return
    const update = () => setInstallReady(canPromptInstall())
    window.addEventListener('qs-install-ready', update)
    let alive = true
    if (supported && signedIn) registerStaffWorker().then(async (registration) => {
      const subscription = await registration.pushManager.getSubscription()
      if (!subscription) return
      const result = await staffPushRequest('status', { app, endpoint: subscription.endpoint })
      if (alive) setEnabled(result.enabled)
    }).catch(() => {})
    return () => { alive = false; window.removeEventListener('qs-install-ready', update) }
  }, [browser, supported, signedIn, app])

  const install = async () => {
    if (installReady) { await promptInstall(); setInstallReady(false) }
    else setMessage(/iPhone|iPad|iPod/.test(navigator.userAgent)
      ? 'In Safari, tap Share, then Add to Home Screen.'
      : 'Use your browser’s Install app option or the install icon beside the address bar.')
  }
  const notificationAction = async (action) => {
    setBusy(true); setMessage('')
    try {
      if (!supported) throw new Error('For iPhone notifications, first add the café app to your Home Screen and open it there.')
      if (action === 'enable' && await Notification.requestPermission() !== 'granted') throw new Error('Notifications are blocked. Allow them in your device or browser settings, then try again.')
      const registration = await registerStaffWorker()
      let subscription = await registration.pushManager.getSubscription()
      if (action === 'enable') {
        const config = await staffPushRequest('config', { app })
        subscription ||= await registration.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: decodeApplicationKey(config.publicKey) })
        await staffPushRequest('subscribe', { app, subscription: subscription.toJSON() })
        setEnabled(true); setMessage('Notifications enabled on this device.')
      } else if (action === 'disable') {
        if (subscription) await staffPushRequest('unsubscribe', { app, endpoint: subscription.endpoint })
        // One browser worker can serve both installed apps: disable only this app's subscription row.
        setEnabled(false); setMessage('Notifications turned off for this app on this device.')
      } else {
        if (!subscription) throw new Error('Enable notifications first.')
        await staffPushRequest('test', { app, endpoint: subscription.endpoint })
        setMessage('Test alert queued. It should arrive within a minute.')
      }
    } catch (error) { setMessage(error.message || 'Could not update notifications. Try again.') }
    finally { setBusy(false) }
  }
  if (!browser) return null
  return <div className="qs-staff-app-controls">
    {!standalone && <button type="button" onClick={install}>Install {app === 'admin' ? 'Admin' : 'Counter'}</button>}
    {signedIn && <button type="button" disabled={busy} onClick={() => notificationAction(enabled ? 'disable' : 'enable')}>{busy ? 'Please wait…' : enabled ? 'Turn alerts off' : 'Enable alerts'}</button>}
    {signedIn && enabled && <button type="button" disabled={busy} onClick={() => notificationAction('test')}>Test alert</button>}
    {message && <p role="status">{message}</p>}
  </div>
}
