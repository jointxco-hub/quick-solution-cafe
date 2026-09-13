import fs from 'node:fs'
import path from 'node:path'

const root = process.cwd()

function update(relative, fn) {
  const file = path.join(root, relative)
  if (!fs.existsSync(file)) throw new Error(`Missing ${relative}`)
  const before = fs.readFileSync(file, 'utf8')
  const after = fn(before)
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

update('src/components/GuidedOrder.jsx', (text) => {
  text = replaceOnce(
    text,
    "import Icon from './Icon.jsx'\n",
    "import Icon from './Icon.jsx'\nimport PaymentRedirectLoader from './PaymentRedirectLoader.jsx'\n",
    'PaymentRedirectLoader import'
  )

  const anchor = "    const whatsappText = encodeURIComponent(`Hi Quick Solution, my order is ${orderNumber}. I need help with the file or next step.`)\n\n    return ("
  const replacement = "    const whatsappText = encodeURIComponent(`Hi Quick Solution, my order is ${orderNumber}. I need help with the file or next step.`)\n\n    if (paymentState === 'starting') {\n      return <PaymentRedirectLoader orderNumber={orderNumber} amount={total}/>\n    }\n\n    return ("

  text = replaceOnce(
    text,
    anchor,
    replacement,
    'secure payment loader render'
  )

  return text
})

update('src/main.jsx', (text) => {
  const existing = "import './styles/qs084.css'\n"
  if (text.includes(existing)) {
    return replaceOnce(
      text,
      existing,
      existing + "import './styles/qs085.css'\n",
      'QS-08.5 CSS import'
    )
  }

  return replaceOnce(
    text,
    "import './styles/qs08.css'\n",
    "import './styles/qs08.css'\nimport './styles/qs085.css'\n",
    'QS-08.5 CSS import fallback'
  )
})

console.log('')
console.log('QS-08.5 secure payment loader applied.')
console.log('Run: npm run dev')
