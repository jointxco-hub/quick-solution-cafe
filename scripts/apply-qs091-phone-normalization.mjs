import fs from 'node:fs'
import path from 'node:path'

const file = path.join(process.cwd(), 'src/components/TrackOrder.jsx')
if (!fs.existsSync(file)) throw new Error('Missing src/components/TrackOrder.jsx')

let source = fs.readFileSync(file, 'utf8')

source = source.replace(
  'placeholder="Same contact used on the order"',
  'placeholder="e.g. 067 123 4567, +27 67 123 4567, or email"'
)

source = source.replace(
  'same email or WhatsApp number used at checkout.',
  'same email or WhatsApp number used at checkout. Local 0-number and +27 formats both work.'
)

fs.writeFileSync(file, source, 'utf8')
console.log('QS-09.1 tracking contact UX updated.')
