import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'
import { findQuickSolutionTrackingSessionByOrderNumber } from '../src/lib/trackingSession.js'

test('saved same-browser tracking session can be found by order number regardless of case', () => {
  const key='qsc_tracking_session_v1:order-123'
  const data=JSON.stringify({orderId:'order-123',orderNumber:'QS-261115-1E4A',trackingToken:'test-token',trackingTokenExpiresAt:'2099-01-01T00:00:00Z'})
  global.window={localStorage:{length:1,key:i=>i===0?key:null,getItem:k=>k===key?data:null}}
  try {
    assert.equal(findQuickSolutionTrackingSessionByOrderNumber('qs-261115-1e4a').trackingToken,'test-token')
    assert.equal(findQuickSolutionTrackingSessionByOrderNumber('OTHER'),null)
  } finally {delete global.window}
})

test('expired, malformed, or unrelated sessions are not selected',()=>{
  const values=[
    ['qsc_tracking_session_v1:a',JSON.stringify({orderNumber:'QS-X',trackingToken:'old',trackingTokenExpiresAt:'2020-01-01T00:00:00Z'})],
    ['qsc_tracking_session_v1:b','{bad-json'],
    ['unrelated',JSON.stringify({orderNumber:'QS-X',trackingToken:'not-from-our-app'})]
  ]
  const store=new Map(values)
  global.window={localStorage:{length:store.size,key:i=>[...store.keys()][i],getItem:k=>store.get(k)}}
  try{assert.equal(findQuickSolutionTrackingSessionByOrderNumber('QS-X'),null)}
  finally{delete global.window}
})

test('frontend only retries a missing contact result using the saved backend-verified token',()=>{
  const code=readFileSync('src/components/TrackOrder.jsx','utf8')
  assert.match(code,/if \(!result\?\.order\?\.orderNumber && !secureToken\)/)
  assert.match(code,/findQuickSolutionTrackingSessionByOrderNumber\(nextOrder\)/)
  assert.match(code,/trackingToken: saved\.trackingToken/)
  assert.match(code,/contact: null/)
})
