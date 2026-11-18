import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { resolveQuickSolutionPaymentFunction as route } from '../src/lib/payfastCanaryRoute.js'

const stagingApi = 'https://tijiamrfnxrbitafiflj.supabase.co'
const productionApi = 'https://slhcvyeuqsduaglddqdb.supabase.co'

test('isolated staging hostname and staging backend select hardened canary',()=>{
  assert.equal(route('quick-solution-cafe-staging-k4gtl55sb-joint-x.vercel.app',stagingApi),'quick-solution-payfast-browser-opps106-test')
  assert.equal(route('quick-solution-cafe-staging.vercel.app',stagingApi),'quick-solution-payfast-browser-opps106-test')
})

test('public Café, wrong backend and unrelated previews cannot select test canary',()=>{
  assert.equal(route('cafe.jointx.co.za',stagingApi),'quick-solution-payfast')
  assert.equal(route('cafe.jointx.co.za',productionApi),'quick-solution-payfast')
  assert.equal(route('quick-solution-cafe-staging-k4gtl55sb-joint-x.vercel.app',productionApi),'quick-solution-payfast')
  assert.equal(route('unrelated-preview.vercel.app',stagingApi),'quick-solution-payfast')
  assert.equal(route('quick-solution-cafe-staging-evil.vercel.app.attacker.test',stagingApi),'quick-solution-payfast')
  assert.equal(route('quick-solution-cafe-staging.vercel.app','invalid'),'quick-solution-payfast')
})

test('storefront shares the same selected payment endpoint for init and status',()=>{
  const src=readFileSync('src/lib/supabaseApi.js','utf8')
  assert.match(src,/const paymentFunction = resolveQuickSolutionPaymentFunction\(window\.location\.hostname, SUPABASE_URL\)/)
  assert.match(src,/functions\/v1\/\$\{paymentFunction\}/)
  assert.match(src,/action: 'init'/)
  assert.match(src,/action: 'status'/)
})
