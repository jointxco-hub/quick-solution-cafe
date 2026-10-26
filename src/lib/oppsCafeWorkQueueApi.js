// Issue #106: authenticated read-only OPPS work queue transport.
// The RPC must enforce tenant membership and calculate balances on the server.
// No client-provided tenant identifier and no payment/handoff mutation here.
import { getAdminSession } from './supabaseApi.js'

const baseUrl = String(import.meta.env.VITE_SUPABASE_URL || '').replace(/\/$/, '')
const publishableKey = String(import.meta.env.VITE_SUPABASE_PUBLISHABLE_KEY || import.meta.env.VITE_SUPABASE_ANON_KEY || '')

export async function fetchOppsCafeWorkQueue({ signal } = {}) {
  const session = getAdminSession()
  if (!session?.access_token) throw new Error('Staff sign-in is required.')
  if (!baseUrl || !publishableKey) throw new Error('Café backend is not configured.')
  // Disabled until the reviewed, tenant-scoped backend migration is installed.
  if (import.meta.env.VITE_OPPS_CAFE_QUEUE_ENABLED !== 'true') {
    throw new Error('OPPS work queue is not enabled on this environment.')
  }
  // A preview flag alone is insufficient: never query the live backend from this staging feature.
  if (baseUrl !== 'https://tijiamrfnxrbitafiflj.supabase.co') {
    throw new Error('OPPS work queue requires the isolated XOS staging backend.')
  }
  const response = await fetch(baseUrl + '/rest/v1/rpc/list_cafe_opps_work_queue', {
    method: 'POST',
    headers: {
      apikey: publishableKey,
      Authorization: 'Bearer ' + session.access_token,
      'Content-Type': 'application/json'
    },
    body: '{}',
    signal
  })
  const body = await response.json().catch(() => null)
  if (!response.ok) throw new Error(body?.message || body?.error || 'Could not load OPPS work queue.')
  if (!body || !Array.isArray(body.items)) throw new Error('Unexpected work queue response.')
  return body
}
