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

// App: render a dedicated PayFast return/recovery page.
edit('src/App.jsx', (text) => {
  text = replaceOnce(
    text,
    "import GuidedOrder from './components/GuidedOrder.jsx'\n",
    "import GuidedOrder from './components/GuidedOrder.jsx'\nimport PaymentReturn from './components/PaymentReturn.jsx'\n",
    'PaymentReturn import'
  )

  text = replaceOnce(
    text,
    "  if (view === 'admin') {\n",
    "  const paymentMode = new URLSearchParams(window.location.search).get('qs_payment')\n  if (paymentMode === 'return' || paymentMode === 'cancel') {\n    return <PaymentReturn/>\n  }\n\n  if (view === 'admin') {\n",
    'payment return route'
  )

  return text
})

// GuidedOrder: persist the secure payment session and use same-tab redirect.
edit('src/components/GuidedOrder.jsx', (text) => {
  text = replaceOnce(
    text,
    "import { beginQuickSolutionPayment, createQuickSolutionOrder, getQuickSolutionPaymentStatus, isSupabaseConfigured, uploadQuickSolutionFile } from '../lib/supabaseApi.js'\n",
    "import { beginQuickSolutionPayment, createQuickSolutionOrder, getQuickSolutionPaymentStatus, isSupabaseConfigured, uploadQuickSolutionFile } from '../lib/supabaseApi.js'\nimport { saveQuickSolutionPaymentSession } from '../lib/paymentSession.js'\n",
    'payment session import'
  )

  text = replaceOnce(
    text,
    "      setOrderResponse(response)\n",
    "      setOrderResponse(response)\n      if (response?.orderId && response?.paymentToken) {\n        saveQuickSolutionPaymentSession({\n          orderId: response.orderId,\n          paymentToken: response.paymentToken,\n          orderNumber: response.orderNumber,\n          amount: response.totalAmount\n        })\n      }\n",
    'save payment session after order creation'
  )

  text = replaceOnce(
    text,
    "      window.open(result.payment_url, '_blank', 'noopener,noreferrer')\n      setPaymentState('waiting')\n",
    "      saveQuickSolutionPaymentSession({\n        orderId: orderResponse.orderId,\n        paymentToken: orderResponse.paymentToken,\n        orderNumber: orderResponse.orderNumber,\n        amount: orderResponse.totalAmount\n      })\n      setPaymentState('waiting')\n      window.location.assign(result.payment_url)\n",
    'same-tab PayFast redirect'
  )

  // Repair any lingering Windows mojibake from the older QS-08 PowerShell patch.
  const replacements = new Map([
    ['Â·', '·'],
    ['â€“', '–'],
    ['â€”', '—'],
    ['â€™', '’'],
    ['â€˜', '‘'],
    ['â€œ', '“'],
    ['â€', '”'],
    ['â€¢', '•'],
    ['â†’', '→'],
    ['â€¦', '…'],
    ['Â', '']
  ])
  for (const [bad, good] of replacements) text = text.split(bad).join(good)

  return text
})

// Main stylesheet.
edit('src/main.jsx', (text) => {
  text = replaceOnce(
    text,
    "import './styles/qs08.css'\n",
    "import './styles/qs08.css'\nimport './styles/qs084.css'\n",
    'QS-08.4 stylesheet'
  )
  return text
})

console.log('')
console.log('QS-08.4 payment return flow applied.')
console.log('Run: npm run dev')
