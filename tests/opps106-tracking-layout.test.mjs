import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'

test('tracking steps use the count returned by the backend, not hard-coded four columns',()=>{
  const jsx=readFileSync('src/components/TrackOrder.jsx','utf8')
  const css=readFileSync('src/styles/qs09.css','utf8')
  assert.match(jsx,/--tracking-step-count[^\n]*timeline\.length/)
  assert.match(css,/grid-template-columns:\s*repeat\(var\(--tracking-step-count, 4\), minmax\(0, 1fr\)\)/)
  assert.doesNotMatch(css,/grid-template-columns:\s*repeat\(4, 1fr\)/)
  assert.match(css,/left:\s*calc\(100% \/ var\(--tracking-step-count, 4\) \/ 2\)/)
  assert.match(css,/right:\s*calc\(100% \/ var\(--tracking-step-count, 4\) \/ 2\)/)
})
