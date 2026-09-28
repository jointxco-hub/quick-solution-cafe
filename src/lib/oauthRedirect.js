// Pure parse of GoTrue's OAuth implicit-grant redirect fragment - kept in
// its own dependency-free module (no import.meta.env, no window) for the
// same reason src/lib/navigation.js's route/history helpers are split out
// from App.jsx: this repo's test suite is plain Node --test with no DOM/
// import.meta.env shim, and supabaseApi.js reads import.meta.env at
// module top level, which throws under plain Node the instant anything
// is imported from it - so anything meant to get a REAL, executed test
// (not just a text-pattern match against the source, like supabaseApi.js
// itself gets) has to live somewhere free of that. supabaseApi.js's own
// consumeOAuthRedirectResult() is the side-effecting wrapper: it reads
// the real window.location.hash, calls this, then owns storing the
// session / stripping the fragment from the URL.
//
// GoTrue's /auth/v1/authorize redirects back with the session in the URL
// fragment (`#access_token=...&refresh_token=...&expires_in=...`) - the
// plain implicit grant, since nothing here ever sends a `code_challenge`
// to switch it to the PKCE code-exchange flow - or with `#error=...&
// error_description=...` if the user cancelled consent or the provider
// rejected the request. Returns null for an ordinary page load (no
// relevant params in the hash at all), so callers can tell "this was not
// an OAuth return" apart from "OAuth returned an error".
export function parseOAuthRedirectHash(hash) {
  if (!hash || hash.length < 2) return null
  const params = new URLSearchParams(hash.startsWith('#') ? hash.slice(1) : hash)
  if (!params.has('access_token') && !params.has('error')) return null

  const errorDescription = params.get('error_description') || params.get('error')
  if (errorDescription) return { error: errorDescription.replace(/\+/g, ' ') }

  const accessToken = params.get('access_token')
  const refreshToken = params.get('refresh_token')
  if (!accessToken || !refreshToken) return { error: 'Google sign-in did not return a valid session.' }

  return {
    payload: {
      access_token: accessToken,
      refresh_token: refreshToken,
      expires_in: params.get('expires_in'),
      expires_at: params.get('expires_at'),
      token_type: params.get('token_type') || 'bearer'
    }
  }
}
