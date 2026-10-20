// Public portfolio RPC. The server must enforce publication and media visibility.
// This client never requests draft or private customer/order data.
const URL = String(import.meta.env.VITE_SUPABASE_URL || '').replace(/\/$/, '')
const KEY = String(import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY || import.meta.env.VITE_SUPABASE_ANON_KEY || '')
const TENANT = String(import.meta.env.VITE_QS_TENANT_SLUG || 'quick-solution')

export async function loadPublishedPortfolio() {
  if (!URL || !KEY) return []
  const response = await fetch(`${URL}/rest/v1/rpc/get_quick_solution_portfolio`, {
    method: 'POST',
    headers: { apikey: KEY, 'Content-Type': 'application/json', ...(KEY.startsWith('eyJ') ? { Authorization: `Bearer ${KEY}` } : {}) },
    body: JSON.stringify({ p_tenant_slug: TENANT })
  })
  if (!response.ok) throw new Error('Published portfolio is unavailable')
  const result = await response.json()
  return Array.isArray(result) ? result : Array.isArray(result?.projects) ? result.projects : []
}
