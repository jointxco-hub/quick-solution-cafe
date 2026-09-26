// Test-only: renders the real Counter React components to HTML in plain Node, with no jsdom and no
// browser. esbuild (already installed with vite) bundles the actual source; the ONE thing replaced is the
// API module, at the UI boundary, by a mock the tests control through globalThis.__counterApiMock. Nothing
// here can reach Supabase, and the mock exposes createQuickSolutionCounterOrder, recordQuickSolutionCounterPayment and cancelQuickSolutionCounterOrder as its only writes, so
// any other API import from the Counter would fail the bundle.

import { build } from 'esbuild'
import { createRequire } from 'node:module'
import path from 'node:path'
import { fileURLToPath } from 'node:url'

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..', '..')

const MOCK_API = `
const m = () => globalThis.__counterApiMock
export const getAdminSession = () => m().session
export const loadQuickSolutionCounterCatalog = (...args) => m().load(...args)
export const createQuickSolutionCounterOrder = (...args) => m().create(...args)
export const loadQuickSolutionCounterOrdersToday = (...args) => m().listToday(...args)
export const loadQuickSolutionCounterOrder = (...args) => m().detail(...args)
export const loadQuickSolutionCounterCashupToday = (...args) => m().cashup(...args)
export const loadQuickSolutionCounterCashup = (...args) => m().cashupOn(...args)
export const loadQuickSolutionUnpaidCounterOrders = (...args) => m().unpaid(...args)
export const recordQuickSolutionCounterPayment = (...args) => m().pay(...args)
export const loadQuickSolutionCancelledCounterOrders = (...args) => (m().cancelled ? m().cancelled(...args) : Promise.reject(Object.assign(new Error('Only a Quick Solution admin or owner can view cancelled counter orders.'), { status: 403, payload: { code: '42501' } })))
export const loadQuickSolutionCounterOrderCancelCheck = (...args) => (m().cancelCheck ? m().cancelCheck(...args) : Promise.resolve({ orderId: args[0], permitted: false, cancellable: true, block: null }))
export const cancelQuickSolutionCounterOrder = (...args) => m().cancel(...args)
export const signInAdmin = (...args) => m().signIn(...args)
export const signOutAdmin = (...args) => m().signOut(...args)
`

const ENTRY = `
import React from 'react'
import { renderToStaticMarkup } from 'react-dom/server'
import CounterPage from './src/counter/CounterPage.jsx'
import CounterView from './src/counter/CounterView.jsx'
export { React, renderToStaticMarkup, CounterPage, CounterView }
`

let loaded = null

export async function loadCounterUi() {
  if (loaded) return loaded
  const result = await build({
    stdin: { contents: ENTRY, resolveDir: root, sourcefile: 'counter-ui-entry.jsx', loader: 'jsx' },
    bundle: true,
    write: false,
    platform: 'node',
    format: 'cjs',
    logLevel: 'silent',
    loader: { '.css': 'empty', '.js': 'jsx' },
    define: { 'process.env.NODE_ENV': '"production"' },
    plugins: [{
      name: 'mock-supabase-api',
      setup(b) {
        b.onResolve({ filter: /supabaseApi\.js$/ }, () => ({ path: 'supabaseApi-mock', namespace: 'mock-api' }))
        b.onLoad({ filter: /.*/, namespace: 'mock-api' }, () => ({ contents: MOCK_API, loader: 'js' }))
      }
    }]
  })
  const module = { exports: {} }
  new Function('module', 'exports', 'require', result.outputFiles[0].text)(module, module.exports, createRequire(import.meta.url))
  loaded = module.exports
  return loaded
}

export function setApiMock(mock) {
  globalThis.__counterApiMock = mock
}
