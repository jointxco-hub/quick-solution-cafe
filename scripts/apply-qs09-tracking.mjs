import fs from 'node:fs'
import path from 'node:path'

const root = process.cwd()

function edit(relative, transform) {
  const file = path.join(root, relative)
  if (!fs.existsSync(file)) throw new Error(`Missing ${relative}`)
  const before = fs.readFileSync(file, 'utf8')
  const after = transform(before)
  if (after === before) {
    console.log(`No change: ${relative}`)
    return
  }
  fs.writeFileSync(file, after, 'utf8')
  console.log(`Updated: ${relative}`)
}

function replaceOnce(text, oldValue, newValue, label) {
  if (text.includes(newValue)) return text
  const index = text.indexOf(oldValue)
  if (index < 0) throw new Error(`Could not find anchor: ${label}`)
  return text.slice(0, index) + newValue + text.slice(index + oldValue.length)
}

// App route.
edit('src/App.jsx', (text) => {
  text = replaceOnce(
    text,
    "import PaymentReturn from './components/PaymentReturn.jsx'\n",
    "import PaymentReturn from './components/PaymentReturn.jsx'\nimport TrackOrder from './components/TrackOrder.jsx'\n",
    'TrackOrder import'
  )

  text = replaceOnce(
    text,
    "  const paymentMode = new URLSearchParams(window.location.search).get('qs_payment')\n",
    "  if (window.location.pathname === '/track') {\n    return <TrackOrder/>\n  }\n\n  const paymentMode = new URLSearchParams(window.location.search).get('qs_payment')\n",
    'TrackOrder route'
  )
  return text
})

// Header links work on both storefront and /track.
edit('src/components/Header.jsx', (text) => {
  if (!text.includes("const homePrefix =")) {
    text = replaceOnce(
      text,
      "export default function Header() {\n  return (\n",
      "export default function Header() {\n  const homePrefix = window.location.pathname === '/' ? '' : '/'\n  return (\n",
      'Header route prefix'
    )
  }

  text = text
    .replace('href="#top"', 'href={homePrefix ? \'/\' : \'#top\'}')
    .replace('href="#start"', 'href={`${homePrefix}#start`}')
    .replace('href="#services"', 'href={`${homePrefix}#services`}')
    .replace('href="#quick-points"', 'href={`${homePrefix}#quick-points`}')
    .replace('href="#configure"', 'href={`${homePrefix}#configure`}')

  if (!text.includes('href="/track"')) {
    text = replaceOnce(
      text,
      '<a href={`${homePrefix}#quick-points`}><Icon name="pin" size={16}/> Quick Points</a>\n',
      '<a href={`${homePrefix}#quick-points`}><Icon name="pin" size={16}/> Quick Points</a>\n        <a href="/track"><Icon name="search" size={15}/> Track order</a>\n',
      'Header Track order link'
    )
  }

  return text
})

// Public tracking API + admin link issue helper.
edit('src/lib/supabaseApi.js', (text) => {
  if (!text.includes('export async function getQuickSolutionTracking')) {
    text += `

export async function getQuickSolutionTracking({ orderNumber, trackingToken = null, contact = null }) {
  return rpc('get_quick_solution_tracking', {
    p_order_number: String(orderNumber || '').trim(),
    p_tracking_token: trackingToken || null,
    p_contact: contact || null
  })
}

export async function adminIssueQuickSolutionTrackingToken(serviceOrderId) {
  const accessToken = await getAdminAccessToken()
  return rpc('admin_issue_quick_solution_tracking_token', {
    p_service_order_id: serviceOrderId
  }, { accessToken })
}
`
  }
  return text
})

// Guided checkout: save tracking token + show Track this order.
edit('src/components/GuidedOrder.jsx', (text) => {
  if (!text.includes("saveQuickSolutionTrackingSession")) {
    text = replaceOnce(
      text,
      "import { saveQuickSolutionPaymentSession } from '../lib/paymentSession.js'\n",
      "import { saveQuickSolutionPaymentSession } from '../lib/paymentSession.js'\nimport { buildQuickSolutionTrackingHref, saveQuickSolutionTrackingSession } from '../lib/trackingSession.js'\n",
      'tracking session import'
    )
  }

  if (!text.includes('trackingTokenExpiresAt: response.trackingTokenExpiresAt')) {
    text = replaceOnce(
      text,
      "      setOrderResponse(response)\n",
      "      setOrderResponse(response)\n      if (response?.orderId && response?.orderNumber && response?.trackingToken) {\n        saveQuickSolutionTrackingSession({\n          orderId: response.orderId,\n          orderNumber: response.orderNumber,\n          trackingToken: response.trackingToken,\n          trackingTokenExpiresAt: response.trackingTokenExpiresAt\n        })\n      }\n",
      'save tracking session'
    )
  }

  if (!text.includes('const trackingHref = orderResponse?.trackingToken')) {
    text = replaceOnce(
      text,
      "    const whatsappText = encodeURIComponent(`Hi Quick Solution, my order is ${orderNumber}. I need help with the file or next step.`)\n",
      "    const whatsappText = encodeURIComponent(`Hi Quick Solution, my order is ${orderNumber}. I need help with the file or next step.`)\n    const trackingHref = orderResponse?.trackingToken\n      ? buildQuickSolutionTrackingHref(orderNumber, orderResponse.trackingToken)\n      : '/track'\n",
      'confirmation tracking href'
    )
  }

  if (!text.includes('Track this order</a>')) {
    text = replaceOnce(
      text,
      '          <button className="button ghost" type="button" onClick={resetOrder}>Start another order</button>\n',
      '          <a className="button dark" href={trackingHref}><Icon name="search" size={16}/> Track this order</a>\n          <button className="button ghost" type="button" onClick={resetOrder}>Start another order</button>\n',
      'confirmation tracking button'
    )
  }

  return text
})

// Payment return: link into tracker using the session saved at order creation.
edit('src/components/PaymentReturn.jsx', (text) => {
  if (!text.includes("readQuickSolutionTrackingSession")) {
    text = replaceOnce(
      text,
      "} from '../lib/paymentSession.js'\n",
      "} from '../lib/paymentSession.js'\nimport { buildQuickSolutionTrackingHref, readQuickSolutionTrackingSession } from '../lib/trackingSession.js'\n",
      'payment return tracking import'
    )
  }

  if (!text.includes('const trackingSession = useMemo')) {
    text = replaceOnce(
      text,
      "  const session = useMemo(() => readQuickSolutionPaymentSession(orderId), [orderId])\n",
      "  const session = useMemo(() => readQuickSolutionPaymentSession(orderId), [orderId])\n  const trackingSession = useMemo(() => readQuickSolutionTrackingSession(orderId), [orderId])\n",
      'payment return tracking session'
    )
  }

  if (!text.includes('const trackingHref = trackingSession')) {
    text = replaceOnce(
      text,
      "  const amount = session?.amount || status?.amount || 0\n",
      "  const amount = session?.amount || status?.amount || 0\n  const trackingHref = trackingSession?.trackingToken\n    ? buildQuickSolutionTrackingHref(trackingSession.orderNumber || orderNumber, trackingSession.trackingToken)\n    : '/track'\n",
      'payment return tracking href'
    )
  }

  text = text.replace("icon: 'check'", "icon: 'checkCircle'")
  text = text.replace("icon: 'close'", "icon: 'xCircle'")

  if (!text.includes('Track this order</a>')) {
    text = replaceOnce(
      text,
      '            <a className="button ghost" href="/">Back to Quick Solution</a>\n',
      '            <a className="button primary-green" href={trackingHref}><Icon name="search" size={16}/> Track this order</a>\n            <a className="button ghost" href="/">Back to Quick Solution</a>\n',
      'payment return tracking button'
    )
  }

  return text
})

// Admin: staff can create/copy a secure customer tracking link for any service order.
edit('src/admin/AdminOppsHandoffPanel.jsx', (text) => {
  if (!text.includes('adminIssueQuickSolutionTrackingToken')) {
    text = replaceOnce(
      text,
      "  buildOppsAppUrl,\n",
      "  adminIssueQuickSolutionTrackingToken,\n  buildOppsAppUrl,\n",
      'admin tracking API import'
    )
  }

  if (!text.includes("const [issuingTrackingId")) {
    text = replaceOnce(
      text,
      "  const [sendingId, setSendingId] = useState('')\n",
      "  const [sendingId, setSendingId] = useState('')\n  const [issuingTrackingId, setIssuingTrackingId] = useState('')\n",
      'admin tracking state'
    )
  }

  if (!text.includes('const copyCustomerTrackingLink = async')) {
    text = replaceOnce(
      text,
      "  const copyOppsId = async () => {\n",
      `  const copyCustomerTrackingLink = async () => {
    if (!selected?.serviceOrderId) return
    setIssuingTrackingId(selected.serviceOrderId)
    setError('')
    try {
      const result = await adminIssueQuickSolutionTrackingToken(selected.serviceOrderId)
      if (!result?.trackingToken || !result?.orderNumber) throw new Error('Tracking link could not be created.')
      const params = new URLSearchParams({
        order: result.orderNumber,
        token: result.trackingToken
      })
      const link = \`\${window.location.origin}/track?\${params.toString()}\`
      if (navigator?.clipboard) {
        await navigator.clipboard.writeText(link)
        setNotice('Customer tracking link copied.')
      } else {
        window.prompt('Copy customer tracking link', link)
      }
    } catch (nextError) {
      setError(nextError?.message || 'Could not create the customer tracking link.')
    } finally {
      setIssuingTrackingId('')
    }
  }

  const copyOppsId = async () => {
`,
      'admin copy tracking function'
    )
  }

  if (!text.includes('Copy tracking link')) {
    text = replaceOnce(
      text,
      '                <div className="handoff-preview-actions">\n',
      '                <div className="handoff-preview-actions">\n                  <button type="button" className="qs-track-copy-button" onClick={copyCustomerTrackingLink} disabled={issuingTrackingId === selected.serviceOrderId}><Icon name="copy" size={16}/> {issuingTrackingId === selected.serviceOrderId ? \'Creating…\' : \'Copy tracking link\'}</button>\n',
      'admin tracking button'
    )
  }

  // Repair lingering mojibake if an older checkout patch was applied through Windows PowerShell.
  const replacements = new Map([
    ['Â·', '·'], ['â€“', '–'], ['â€”', '—'], ['â€™', '’'],
    ['â€˜', '‘'], ['â€œ', '“'], ['â€', '”'], ['â€¢', '•'],
    ['â†’', '→'], ['â€¦', '…'], ['Â', '']
  ])
  for (const [bad, good] of replacements) text = text.split(bad).join(good)

  return text
})

// Styles.
edit('src/main.jsx', (text) => {
  if (text.includes("import './styles/qs09.css'")) return text
  const anchors = [
    "import './styles/qs085.css'\n",
    "import './styles/qs084.css'\n",
    "import './styles/qs08.css'\n"
  ]
  const anchor = anchors.find((item) => text.includes(item))
  if (!anchor) throw new Error('Could not find stylesheet import anchor in src/main.jsx')
  return replaceOnce(
    text,
    anchor,
    anchor + "import './styles/qs09.css'\n",
    'QS-09 stylesheet'
  )
})

console.log('')
console.log('QS-09 customer tracking UI applied.')
console.log('Run: npm run dev')
