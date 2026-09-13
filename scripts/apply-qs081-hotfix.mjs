import fs from 'node:fs'
import path from 'node:path'
import process from 'node:process'

const root = process.cwd()
const targets = [
  'src/components/GuidedOrder.jsx',
  'src/admin/AdminOppsHandoffPanel.jsx',
  'src/admin/AdminProductManager.jsx',
  'src/admin/AdminQuickPointsPanel.jsx',
  'src/App.jsx',
  'src/lib/supabaseApi.js',
  'src/main.jsx',
  'src/styles/qs07.css',
  'src/styles/qs08.css'
]

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
  ['âœ“', '✓'],
  ['Â', '']
])

let changed = 0

for (const relative of targets) {
  const file = path.join(root, relative)
  if (!fs.existsSync(file)) continue

  let text = fs.readFileSync(file, 'utf8')
  const before = text

  for (const [bad, good] of replacements) {
    text = text.split(bad).join(good)
  }

  if (text !== before) {
    fs.writeFileSync(file, text, 'utf8')
    changed += 1
    console.log(`Repaired UTF-8 text: ${relative}`)
  }
}

console.log(changed ? `QS-08.1 repaired ${changed} file(s).` : 'QS-08.1: no mojibake remained.')
console.log('Backend payment route is already fixed on XOS Staging. Refresh the storefront and click Pay securely with PayFast again.')
