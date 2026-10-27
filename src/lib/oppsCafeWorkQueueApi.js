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


// Creates a fulfillment ticket, not a service order or payment. The RPC enforces
// admin capability, tenant isolation, idempotence and test-record exclusions.
export async function sendOppsWorkToCafe({ sourceType, sourceId }) {
  const session = getAdminSession()
  if (!session?.access_token) throw new Error('Staff sign-in is required.')
  if (import.meta.env.VITE_OPPS_CAFE_QUEUE_ENABLED !== 'true' ||
      baseUrl !== 'https://tijiamrfnxrbitafiflj.supabase.co' ||
      !publishableKey) {
    throw new Error('Counter handoff is only available on isolated staging.')
  }
  if (!['invoice', 'order'].includes(sourceType) || !sourceId) {
    throw new Error('Invalid OPPS record.')
  }
  const response = await fetch(baseUrl + '/rest/v1/rpc/send_opps_work_to_cafe', {
    method: 'POST',
    headers: {
      apikey: publishableKey,
      Authorization: 'Bearer ' + session.access_token,
      'Content-Type': 'application/json'
    },
    body: JSON.stringify({ p_source_type: sourceType, p_source_id: sourceId })
  })
  const body = await response.json().catch(() => null)
  if (!response.ok) throw new Error(body?.message || body?.error || 'Could not send to Café.')
  if (!body?.id || !body?.status) throw new Error('Unexpected handoff response.')
  return body
}
