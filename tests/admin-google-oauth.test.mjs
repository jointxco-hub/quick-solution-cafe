import assert from 'node:assert/strict'
import test from 'node:test'
import fs from 'node:fs'
import { parseOAuthRedirectHash } from '../src/lib/oauthRedirect.js'

const read = (path) => fs.readFileSync(new URL(path, import.meta.url), 'utf8')

// ── Google staff sign-in, added alongside the existing email/password
// path ──────────────────────────────────────────────────────────────────
// parseOAuthRedirectHash is the one piece of real decision logic this
// adds (supabaseApi.js's own consumeOAuthRedirectResult/
// startAdminGoogleSignIn are side-effecting window/localStorage wrappers
// around it, and cannot be imported under plain Node - see
// oauthRedirect.js's header comment - so, same as lib/navigation.js, this
// tests the pure decision directly and checks the wiring into
// AdminProductManager.jsx/supabaseApi.js by reading their source, the
// same way the existing counter-ui.test.mjs etc. already do for that
// file).

test('parseOAuthRedirectHash: an ordinary page load (no hash, or an unrelated hash) is not an OAuth return', () => {
  assert.equal(parseOAuthRedirectHash(''), null)
  assert.equal(parseOAuthRedirectHash(undefined), null)
  assert.equal(parseOAuthRedirectHash('#'), null)
  assert.equal(parseOAuthRedirectHash('#admin'), null)
})

test('parseOAuthRedirectHash: a successful GoTrue implicit-grant redirect returns the session payload storeSession() expects', () => {
  const result = parseOAuthRedirectHash('#access_token=abc.def.ghi&refresh_token=refresh-123&expires_in=3600&expires_at=1893456000&token_type=bearer&provider_token=ignored')
  assert.deepEqual(result, {
    payload: {
      access_token: 'abc.def.ghi',
      refresh_token: 'refresh-123',
      expires_in: '3600',
      expires_at: '1893456000',
      token_type: 'bearer'
    }
  })
})

test('parseOAuthRedirectHash: works without the leading "#" too, matching window.location.hash either way', () => {
  const result = parseOAuthRedirectHash('access_token=abc&refresh_token=def')
  assert.equal(result.payload.access_token, 'abc')
  assert.equal(result.payload.refresh_token, 'def')
})

test('parseOAuthRedirectHash: a cancelled/rejected OAuth attempt surfaces GoTrue\'s error, not a session', () => {
  const result = parseOAuthRedirectHash('#error=access_denied&error_description=User+cancelled+the+consent+screen')
  assert.deepEqual(result, { error: 'User cancelled the consent screen' })
})

test('parseOAuthRedirectHash: a token response missing refresh_token is treated as an error, never a half-formed session', () => {
  const result = parseOAuthRedirectHash('#access_token=abc&token_type=bearer')
  assert.deepEqual(result, { error: 'Google sign-in did not return a valid session.' })
})

test('AdminSignIn keeps the existing email/password form and submit path untouched', () => {
  const source = read('../src/admin/AdminProductManager.jsx')
  assert.match(source, /signInAdmin\(email, password\)/, 'the password submit still calls signInAdmin(email, password)')
  assert.match(source, /type="email"[^]*?type="password"/, 'the email/password fields are both still rendered')
})

test('AdminSignIn adds a clearly secondary "Continue with Google" action, not a replacement for the password submit', () => {
  const source = read('../src/admin/AdminProductManager.jsx')
  assert.match(source, /Continue with Google/)
  assert.match(source, /button ghost admin-auth-google/, 'the Google button uses the ghost (secondary) style, not "button dark" (the primary submit)')
  assert.match(source, /startAdminGoogleSignIn/)
  assert.match(source, /consumeOAuthRedirectResult/)
})

test('Google sign-in reuses the existing onSignedIn callback - no separate authorization path', () => {
  const source = read('../src/admin/AdminProductManager.jsx')
  const googleEffect = source.slice(source.indexOf('const result = consumeOAuthRedirectResult()'), source.indexOf('const submit = async (event) => {'))
  assert.match(googleEffect, /onSignedIn\(result\.session\)/, 'a successful Google redirect is handed to the SAME onSignedIn the password form uses, so it goes through the same loadLiveAdmin()/authorization gate')
})

test('startAdminGoogleSignIn/consumeOAuthRedirectResult stay in supabaseApi.js next to the existing raw-GoTrue-fetch auth calls, not a new @supabase/supabase-js dependency', () => {
  const pkg = JSON.parse(read('../package.json'))
  assert.equal(pkg.dependencies['@supabase/supabase-js'], undefined)
  const source = read('../src/lib/supabaseApi.js')
  assert.match(source, /auth\/v1\/authorize\?provider=google/)
  assert.match(source, /redirect_to=/)
})
