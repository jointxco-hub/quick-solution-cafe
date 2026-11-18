import React, { useEffect, useRef, useState } from 'react'

// Bundled locally with MIT attribution: /vendor/QRCODE-LICENSE.txt.
// Never send the customer's payment URL to a third-party QR image service.
let loader = null
function loadQrCode() {
  if (typeof window === 'undefined') return Promise.reject(new Error('QR display unavailable'))
  if (window.QRCode) return Promise.resolve(window.QRCode)
  if (!loader) loader = new Promise((resolve, reject) => {
    const script = document.createElement('script')
    script.src = '/vendor/qrcode.min.js'
    script.async = true
    script.onload = () => window.QRCode ? resolve(window.QRCode) : reject(new Error('QR library unavailable'))
    script.onerror = () => reject(new Error('Could not load QR image'))
    document.head.appendChild(script)
  }).catch(error => { loader = null; throw error })
  return loader
}

const SCAN_ENDPOINT = 'https://tijiamrfnxrbitafiflj.supabase.co/functions/v1/quick-solution-qr-opps106-scan'
const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[1-8][0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/i
export function isValidCounterScanUrl(link) {
  try {
    const url = new URL(link)
    return url.origin + url.pathname === SCAN_ENDPOINT &&
      url.searchParams.size === 1 && UUID.test(url.searchParams.get('rid') || '') &&
      !url.username && !url.password && !url.hash
  } catch { return false }
}

export default function CounterQr({ request }) {
  const mount = useRef(null)
  const [error,setError] = useState('')
  const [seconds,setSeconds] = useState(0)
  const url = request?.scanUrl || ''
  const safe = isValidCounterScanUrl(url)
  useEffect(() => {
    if (!safe || !mount.current) return
    let cancelled = false
    const container = mount.current
    container.replaceChildren()
    loadQrCode().then(QRCode => {
      if (cancelled || !mount.current) return
      new QRCode(container, {
        text: url, width: 248, height: 248,
        correctLevel: QRCode.CorrectLevel.M
      })
    }).catch(() => { if (!cancelled) setError('QR image unavailable. Use the payment link below.') })
    return () => { cancelled = true; container.replaceChildren() }
  }, [url,safe])

  useEffect(() => {
    if (!request?.expiresAt) return
    const update = () => setSeconds(Math.max(0,Math.ceil((Date.parse(request.expiresAt)-Date.now())/1000)))
    update()
    const timer = setInterval(update,1000)
    return () => clearInterval(timer)
  },[request?.expiresAt])
  if (!safe) return <p role="alert">The payment server returned an invalid scan link. No QR is shown.</p>
  const expired = seconds <= 0
  return <div className="qsc-qr-card" aria-label="Customer scan-to-pay QR">
    <strong>{expired ? 'QR expired' : 'Customer scans to pay'}</strong>
    <p>PayFast sandbox · {request.amountLabel} · Order {request.orderNumber}</p>
    <div className={'qsc-qr-frame' + (expired ? ' qsc-qr-expired' : '')} ref={mount} aria-label="Scannable QR code for sandbox PayFast payment"/>
    {error && <p role="alert">{error}</p>}
    <p className="qsc-qr-timer" aria-live="off">{expired ? 'This code is no longer valid. Do not reuse it.' : 'Expires in ' + Math.floor(seconds/60) + ':' + String(seconds%60).padStart(2,'0')}</p>
    {!expired && <a href={url} target="_blank" rel="noopener noreferrer">Open sandbox payment link</a>}
    <small>Payment is only confirmed when the Café server verifies PayFast. The customer return page alone is not proof.</small>
  </div>
}
