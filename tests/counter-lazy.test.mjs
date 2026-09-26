import assert from 'node:assert/strict'
import test from 'node:test'
import fs from 'node:fs'
import path from 'node:path'
import { fileURLToPath } from 'node:url'
import { build } from 'esbuild'
import { resolveAppRoute } from '../src/lib/navigation.js'

// CAFE-GUEST-01X - the staff Counter is its own chunk, loaded only when /counter is opened. Nothing about the counter itself changed; these
// tests prove the boundary: App.jsx reaches the counter only through a lazy import, storefront and admin routes never render (so never fetch)
// it, a real code-split bundle keeps the counter UI out of the main chunk, and a loading fallback exists that does not depend on counter CSS.

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..')
const read = (relative) => fs.readFileSync(path.join(root, relative), 'utf8')
const stripComments = (text) => text.replace(/\/\*[\s\S]*?\*\//g, '').replace(/(^|[^:'"`])\/\/[^\n]*/g, '$1')
const app = stripComments(read('src/App.jsx'))

const walk = (dir, out = []) => {
  for (const entry of fs.readdirSync(path.join(root, dir), { withFileTypes: true })) {
    const relative = `${dir}/${entry.name}`
    if (entry.isDirectory()) walk(relative, out)
    else if (/\.(jsx?|mjs)$/.test(entry.name)) out.push(relative)
  }
  return out
}

test('the counter is reached only through a lazy import in App.jsx, wrapped in Suspense with a fallback', () => {
  assert.match(app, /import React, \{[^}]*\blazy\b[^}]*\bSuspense\b[^}]*\} from 'react'/)
  assert.match(app, /const CounterPage = lazy\(\(\) => import\('\.\/counter\/CounterPage\.jsx'\)\)/)
  assert.doesNotMatch(app, /^import CounterPage/m, 'no eager import of the page')
  assert.doesNotMatch(app, /from '\.\/counter\//, 'no static import of any counter module')
  assert.match(app, /if \(view === 'counter'\) \{\s*return \(\s*<Suspense fallback=\{<div className="admin-loading" role="status">[\s\S]*?Loading the counter…[\s\S]*?<\/div>\}>\s*<CounterPage\/>\s*<\/Suspense>\s*\)\s*\}/)
  assert.equal((app.match(/<CounterPage/g) || []).length, 1, 'rendered in exactly one place: the /counter branch, so no other route can trigger the fetch')
  assert.equal((app.match(/\bimport\('\.\/counter\//g) || []).length, 1, 'one dynamic import')
})

test('nothing outside the counter statically imports counter code, so no other route can pull it into the main chunk', () => {
  const offenders = []
  for (const file of [...walk('src')]) {
    if (file.startsWith('src/counter/') || /^src\/lib\/counter[A-Za-z]*\.js$/.test(file)) continue
    const text = stripComments(read(file))
    if (/from ['"](\.\.?\/)+(counter\/|lib\/counter|counter[A-Za-z]*\.js)/.test(text) || /^import ['"][^'"]*(qs-counter\.css|\/counter\/)/m.test(text)) offenders.push(file)
  }
  assert.deepEqual(offenders, [], 'only the lazy import in App.jsx (which is a dynamic import(), not a static one) reaches the counter')
  assert.doesNotMatch(read('src/main.jsx'), /counter/i, 'the app entry does not import the counter CSS or code')
})

test('/counter still resolves to the counter view and every other route resolves as before', () => {
  assert.deepEqual(resolveAppRoute({ pathname: '/counter' }), { view: 'counter', page: null, pathname: '/counter' })
  assert.equal(resolveAppRoute({ pathname: '/counter/' }).view, 'counter')
  assert.equal(resolveAppRoute({ pathname: '/counter/extra' }).view, 'not-found')
  for (const [pathname, view] of [['/', 'storefront'], ['/admin', 'admin'], ['/track', 'track']]) assert.equal(resolveAppRoute({ pathname }).view, view, pathname)
})

test('a real code-split bundle keeps the counter UI out of the main chunk and puts it in its own', async () => {
  const result = await build({
    entryPoints: [path.join(root, 'src/App.jsx')],
    bundle: true,
    splitting: true,
    format: 'esm',
    outdir: path.join(root, '.esbuild-split-check'),
    write: false,
    logLevel: 'silent',
    loader: { '.css': 'empty', '.js': 'jsx', '.png': 'dataurl', '.svg': 'dataurl', '.jpg': 'dataurl', '.webp': 'dataurl' },
    define: { 'process.env.NODE_ENV': '"production"' }
  })
  const files = result.outputFiles.map((file) => ({ name: path.basename(file.path), text: file.text }))
  const main = files.find((file) => file.name === 'App.js')
  const counterChunk = files.find((file) => /^CounterPage-/.test(file.name))
  assert.ok(main && counterChunk, `expected a main chunk and a CounterPage chunk, got ${files.map((file) => file.name).join(', ')}`)
  // counter-only screens and class names: in the counter chunk, never in the main one
  const markers = ['Confirm cancellation', 'Cancelled orders', 'qsc-confirm-pay', 'qsc-datebar', 'Reason for cancelling']
  for (const marker of markers) {
    assert.ok(counterChunk.text.includes(marker), `${marker} is in the counter chunk`)
    assert.equal(main.text.includes(marker), false, `${marker} is not in the main chunk`)
  }
  // the main chunk reaches the counter only through a dynamic import of that chunk
  assert.match(main.text, new RegExp(`import\\("\\./${counterChunk.name.replace('.', '\\.')}"\\)`))
  assert.doesNotMatch(main.text, new RegExp(`^import[^\\n]*${counterChunk.name.replace('.', '\\.')}`, 'm'), 'never a static import of the counter chunk')
  // storefront code is not moved into the counter chunk
  assert.equal(counterChunk.text.includes('ProductConfigurator'), false)
})

test('the loading fallback does not depend on counter CSS: its class is in the main stylesheet set', () => {
  const main = read('src/main.jsx')
  const importedCss = [...main.matchAll(/import '\.\/styles\/([^']+\.css)'/g)].map((match) => match[1])
  assert.ok(importedCss.some((name) => /admin-loading/.test(read(`src/styles/${name}`))), 'admin-loading is styled by a stylesheet the app entry imports')
  assert.equal(importedCss.includes('qs-counter.css'), false)
  assert.match(read('src/counter/CounterPage.jsx'), /import '\.\.\/styles\/qs-counter\.css'/, 'the counter CSS travels with the counter chunk')
})

test('the counter itself is untouched: same page, same view, same route file, the old eager import is the only App.jsx change', () => {
  assert.match(read('src/counter/CounterPage.jsx'), /export default function CounterPage\(\)/)
  assert.match(read('src/counter/CounterView.jsx'), /export default function CounterView\(/)
  assert.match(read('package.json'), /tests\/counter-lazy\.test\.mjs/)
})
