// QS-18 — Simple/Pro language mode persistence. Presentation-only: never
// stored alongside cart/order data, never sent to the backend, never
// read by pricing.js. Same localStorage convention as cartStore.js
// (namespaced key, try/catch guarded, safe default on any failure).
const MODE_KEY = 'qsc_language_mode_v1'
const PROMPT_SEEN_KEY = 'qsc_language_mode_prompted_v1'

export function loadLanguageMode() {
  if (typeof window === 'undefined') return 'simple'
  try {
    const raw = window.localStorage.getItem(MODE_KEY)
    return raw === 'pro' ? 'pro' : 'simple'
  } catch {
    return 'simple'
  }
}

export function saveLanguageMode(mode) {
  if (typeof window === 'undefined') return
  try {
    window.localStorage.setItem(MODE_KEY, mode === 'pro' ? 'pro' : 'simple')
  } catch {
    // Storage unavailable (private browsing, quota, etc.) - the mode
    // still works for the current session via React state, it just
    // will not be remembered next visit.
  }
}

export function hasSeenLanguageModePrompt() {
  if (typeof window === 'undefined') return true
  try {
    return window.localStorage.getItem(PROMPT_SEEN_KEY) === '1'
  } catch {
    return true
  }
}

export function markLanguageModePromptSeen() {
  if (typeof window === 'undefined') return
  try {
    window.localStorage.setItem(PROMPT_SEEN_KEY, '1')
  } catch {
    // Non-fatal - worst case the prompt reappears next visit.
  }
}
