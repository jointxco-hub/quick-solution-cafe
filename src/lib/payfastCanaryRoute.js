// OPPS-106: the isolated Vercel staging preview routes through the hardened
// sandbox-only PayFast canary. The public Café host and any non-staging
// Supabase project always use the standard checkout endpoint.
export const STANDARD_PAYMENT_FUNCTION = 'quick-solution-payfast'
export const STAGING_PAYMENT_FUNCTION = 'quick-solution-payfast-browser-opps106-test'

export function resolveQuickSolutionPaymentFunction(hostname, supabaseUrl) {
  const host = String(hostname || '').toLowerCase()
  let apiHost = ''
  try { apiHost = new URL(String(supabaseUrl || '')).hostname } catch { return STANDARD_PAYMENT_FUNCTION }

  const stagingDomain =
    (host === 'quick-solution-cafe-staging.vercel.app' ||
    (host.startsWith('quick-solution-cafe-staging-') && host.endsWith('.vercel.app')))
  const stagingBackend = apiHost === 'tijiamrfnxrbitafiflj.supabase.co'
  return stagingDomain && stagingBackend
    ? STAGING_PAYMENT_FUNCTION
    : STANDARD_PAYMENT_FUNCTION
}
