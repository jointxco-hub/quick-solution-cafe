import test from 'node:test'
import assert from 'node:assert/strict'
import { readFileSync } from 'node:fs'

const file = path => readFileSync(path,'utf8')
const ui = file('src/counter/CounterView.jsx')
const page = file('src/counter/CounterPage.jsx')
const qr = file('src/counter/CounterQr.jsx')
const api = file('src/lib/supabaseApi.js')
const sale = file('src/lib/counterSale.js')

test('created counter sale retains server-issued order UUID, not a copied order number',()=>{
  assert.match(sale,/orderId: response\.orderId/)
  assert.match(page,/openOrder\(sale\.result\.orderId, 'sale'\)/)
  assert.match(ui,/onTakePayment\?\.\('cash'\)/)
  assert.match(ui,/onTakePayment\?\.\('card'\)/)
  assert.match(ui,/onTakePayment\?\.\('qr'\)/)
  assert.match(ui,/Leave unpaid · Start new sale/)
})
test('QR is issued from the signed-in Café counter and gated to staging',()=>{
  assert.match(api,/SUPABASE_URL === QR_STAGING_URL/)
  assert.match(api,/getAdminAccessToken\(\)/)
  assert.match(api,/qs_opps106_counter_qr_preflight/)
  assert.match(api,/qs_opps106_issue_counter_qr/)
  assert.doesNotMatch(api,/PAYFAST_MERCHANT_KEY|PAYFAST_PASSPHRASE/)
  assert.match(page,/qrAttempts\.current\[orderId\]/)
})
test('counter displays actual locally generated QR without third party image service',()=>{
  assert.match(qr,/\/vendor\/qrcode\.min\.js/)
  assert.match(qr,/new QRCode\(container/)
  assert.match(qr,/SCAN_ENDPOINT/)
  assert.match(qr,/url\.searchParams\.size === 1/)
  assert.doesNotMatch(qr,/api\.qrserver|chart\.googleapis|quickchart\.io/)
})
test('only the canonical server status confirms paid and pending QR blocks alternate payment',()=>{
  assert.match(page,/fresh\?\.paymentStatus === 'paid'/)
  assert.match(page,/loadQuickSolutionCounterOrder\(openOrderId\)/)
  assert.match(ui,/\['issuing','ready','error'\]\.includes\(qrPayment\?\.phase\)/)
  assert.match(ui,/QR payment confirmed by the Café server/)
  assert.match(ui,/Cash or card remains available/)
})
test('QR does not auto-issue or auto-retry expired or uncertain payments',()=>{
  assert.match(ui,/onClick=\{onStartQr\}/)
  assert.match(page,/if \(qrAttempts\.current\[orderId\]\) return/)
  assert.match(qr,/This code is no longer valid/)
  assert.match(page,/Check the order before trying again/)
})

test('QR component failure cannot replace the entire Counter application',()=>{
 const boundary=file('src/counter/CounterQrBoundary.jsx')
 assert.match(boundary,/getDerivedStateFromError/)
 assert.match(boundary,/QR display unavailable/)
 assert.match(boundary,/this\.props\.children/)
 assert.match(ui,/CounterQrBoundary/)
 assert.match(ui,/<CounterQr request=\{qrPayment\}/)
})

test('QR JSX renderer imports React for the classic JSX transform',()=>{
 const qrSource=file('src/counter/CounterQr.jsx')
 assert.match(qrSource,/^import React, \{ useEffect, useRef, useState \} from 'react'/)
 assert.match(qrSource,/return <div className="qsc-qr-card"/)
})
